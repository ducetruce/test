import Foundation

/// Imports an official Oura data export (`membership.ouraring.com/data-export`).
///
/// This path needs no API token and no membership — it is your data-portability export. The
/// export's exact shape has changed over the years and differs between CSV and JSON, so the
/// importer is deliberately tolerant: it canonicalises column names through a synonym table,
/// infers duration units per record, and reports every column it did *not* recognise so an
/// unfamiliar export can be diagnosed rather than silently half-imported.
enum ExportImporter {

    struct Report {
        var files: [String] = []
        var rowsRead = 0
        var sleepImported = 0
        var activityImported = 0
        var readinessImported = 0
        var skippedExisting = 0
        /// Columns present in the file that no rule maps. Surfaced in the UI on purpose.
        var unmappedColumns: Set<String> = []
        var notes: [String] = []

        var totalImported: Int { sleepImported + activityImported + readinessImported }
    }

    enum ImportError: LocalizedError {
        case unreadable
        case nothingRecognised

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file could not be read."
            case .nothingRecognised:
                return "No rows in that file looked like Oura data. Open Settings → Import to see which columns were found."
            }
        }
    }

    // MARK: - Entry point

    static func importFile(at url: URL, into database: inout Database) throws -> Report {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        var report = Report()

        let files: [ZipArchive.Entry]
        if url.pathExtension.lowercased() == "zip" || looksLikeZip(data) {
            files = try ZipArchive.entries(in: data)
        } else {
            files = [ZipArchive.Entry(name: url.lastPathComponent, data: data)]
        }

        for file in files {
            let lowercased = file.name.lowercased()
            guard lowercased.hasSuffix(".csv") || lowercased.hasSuffix(".json") else { continue }
            report.files.append(file.name)
            let records = lowercased.hasSuffix(".csv")
                ? csvRecords(file.data, report: &report)
                : jsonRecords(file.data)
            report.rowsRead += records.count
            ingest(records, into: &database, report: &report)
        }

        // Rows that were recognised but skipped still count as understood: re-importing an
        // export the API already covers is a no-op, not a failure.
        guard report.totalImported > 0 || report.skippedExisting > 0 else {
            throw ImportError.nothingRecognised
        }
        return report
    }

    private static func looksLikeZip(_ data: Data) -> Bool {
        data.count > 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B
    }

    // MARK: - Reading

    private static func csvRecords(_ data: Data, report: inout Report) -> [[String: String]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let parsed = CSVParser.records(from: text)
        for header in parsed.headers where Field.canonical(header) == nil {
            report.unmappedColumns.insert(header)
        }
        return parsed.records
    }

    /// Accepts either a top-level array of records or an object whose values are arrays
    /// (which is how the JSON export groups sleep / activity / readiness).
    private static func jsonRecords(_ data: Data) -> [[String: String]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var objects: [[String: Any]] = []

        if let array = root as? [[String: Any]] {
            objects = array
        } else if let dictionary = root as? [String: Any] {
            for value in dictionary.values {
                if let array = value as? [[String: Any]] { objects.append(contentsOf: array) }
            }
            if objects.isEmpty { objects = [dictionary] }
        }
        return objects.map(flatten)
    }

    /// Nested objects (`contributors`, `spo2_percentage`) are flattened one level so their
    /// leaves can be matched by the same synonym table.
    private static func flatten(_ object: [String: Any]) -> [String: String] {
        var flat: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let nested as [String: Any]:
                for (innerKey, innerValue) in nested {
                    flat[innerKey] = stringify(innerValue)
                }
            case is [Any]:
                continue
            default:
                flat[key] = stringify(value)
            }
        }
        return flat
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let number as NSNumber: return number.stringValue
        case let text as String: return text
        default: return String(describing: value)
        }
    }

    // MARK: - Mapping

    private static func ingest(_ records: [[String: String]], into database: inout Database, report: inout Report) {
        for record in records {
            let fields = Field.canonicalise(record)
            guard let dayText = fields[.day], let day = Day(String(dayText.prefix(10))) else { continue }

            // Exported rows fill gaps; anything already synced from the API wins.
            if let sleep = sleepPeriod(from: fields, day: day) {
                if database.mainSleep(on: day) == nil {
                    database.merge(sleep: [sleep])
                    report.sleepImported += 1
                } else {
                    report.skippedExisting += 1
                }
            }
            if let activity = activityDay(from: fields, day: day) {
                if database.activityDay(day) == nil {
                    database.merge(activity: [activity])
                    report.activityImported += 1
                } else {
                    report.skippedExisting += 1
                }
            }
            if let readiness = readinessDay(from: fields, day: day) {
                if database.readinessDay(day) == nil {
                    database.merge(readiness: [readiness])
                    report.readinessImported += 1
                } else {
                    report.skippedExisting += 1
                }
            }
        }
    }

    private static func sleepPeriod(from fields: [Field: String], day: Day) -> SleepPeriod? {
        guard let totalRaw = fields.number(.totalSleep), totalRaw > 0 else { return nil }
        let factor = durationFactor(forTotalSleep: totalRaw)
        func duration(_ field: Field) -> TimeInterval { (fields.number(field) ?? 0) * factor }

        let total = totalRaw * factor
        let inBed = fields.number(.timeInBed).map { $0 * factor } ?? total
        let start = fields[.bedtimeStart].flatMap(ISO8601.parse)
            // Without a bedtime, anchor the night so its midpoint lands at 03:00 — the timing
            // contributor is then neutral rather than wrong.
            ?? day.startOfDay().addingTimeInterval(3 * 3600 - total / 2)

        return SleepPeriod(
            id: "export-sleep-\(day)",
            day: day,
            bedtimeStart: start,
            bedtimeEnd: fields[.bedtimeEnd].flatMap(ISO8601.parse) ?? start.addingTimeInterval(inBed),
            type: "long_sleep",
            timeInBed: inBed,
            totalSleep: total,
            deep: duration(.deep),
            light: duration(.light),
            rem: duration(.rem),
            awake: duration(.awake),
            latency: fields.number(.latency).map { $0 * factor },
            efficiency: fields.number(.efficiency),
            restlessPeriods: fields.number(.restlessPeriods).map { Int($0) },
            averageHeartRate: fields.number(.averageHeartRate),
            lowestHeartRate: fields.number(.lowestHeartRate),
            averageHRV: fields.number(.hrv),
            averageBreath: fields.number(.respiratoryRate),
            stages: [],
            heartRate: nil,
            hrv: nil,
            cloudScore: fields.number(.sleepScore).map { Int($0) }
        )
    }

    private static func activityDay(from fields: [Field: String], day: Day) -> ActivityDay? {
        let steps = fields.number(.steps)
        let activeCalories = fields.number(.activeCalories)
        guard steps != nil || activeCalories != nil else { return nil }
        // Activity durations in the export are seconds; there is no ambiguous small value
        // to infer from, so no per-record factor is applied here.
        func seconds(_ field: Field) -> TimeInterval { fields.number(field) ?? 0 }

        return ActivityDay(
            id: "export-activity-\(day)",
            day: day,
            steps: Int(steps ?? 0),
            activeCalories: activeCalories ?? 0,
            totalCalories: fields.number(.totalCalories) ?? 0,
            targetCalories: fields.number(.targetCalories) ?? 0,
            equivalentWalkingDistance: fields.number(.walkingDistance) ?? 0,
            highActivityMinutes: seconds(.highActivityTime) / 60,
            mediumActivityMinutes: seconds(.mediumActivityTime) / 60,
            lowActivityMinutes: seconds(.lowActivityTime) / 60,
            sedentaryTime: seconds(.inactiveTime),
            restingTime: seconds(.restTime),
            nonWearTime: seconds(.nonWearTime),
            inactivityAlerts: Int(fields.number(.inactivityAlerts) ?? 0),
            highActivityMET: fields.number(.highActivityMET) ?? 0,
            mediumActivityMET: fields.number(.mediumActivityMET) ?? 0,
            lowActivityMET: fields.number(.lowActivityMET) ?? 0,
            averageMET: fields.number(.averageMET) ?? 0,
            classes: [],
            met: nil,
            cloudScore: fields.number(.activityScore).map { Int($0) }
        )
    }

    private static func readinessDay(from fields: [Field: String], day: Day) -> ReadinessDay? {
        let score = fields.number(.readinessScore)
        let deviation = fields.number(.temperatureDeviation)
        guard score != nil || deviation != nil else { return nil }
        return ReadinessDay(
            id: "export-readiness-\(day)",
            day: day,
            cloudScore: score.map { Int($0) },
            temperatureDeviation: deviation,
            temperatureTrendDeviation: nil
        )
    }

    /// Exports have used seconds, minutes and hours over the years. Infer from total sleep
    /// once per row and apply the same unit to every duration in that row.
    private static func durationFactor(forTotalSleep value: Double) -> Double {
        if value > 1000 { return 1 }      // seconds
        if value > 20 { return 60 }       // minutes
        return 3600                        // hours
    }
}

/// Canonical column names, with the spellings seen across Oura's CSV and JSON exports.
enum Field: String, CaseIterable, Hashable {
    case day, totalSleep, timeInBed, deep, light, rem, awake, latency, efficiency
    case bedtimeStart, bedtimeEnd, restlessPeriods
    case averageHeartRate, lowestHeartRate, hrv, respiratoryRate, temperatureDeviation
    case sleepScore, readinessScore, activityScore
    case steps, activeCalories, totalCalories, targetCalories, walkingDistance
    case inactiveTime, restTime, lowActivityTime, mediumActivityTime, highActivityTime
    case nonWearTime, inactivityAlerts
    case lowActivityMET, mediumActivityMET, highActivityMET, averageMET

    /// Synonyms are compared after stripping everything but letters and digits, so
    /// "Total Sleep Duration", "total_sleep_duration" and "totalSleepDuration" all match.
    static let synonyms: [Field: [String]] = [
        .day: ["date", "day", "summarydate"],
        .totalSleep: ["totalsleepduration", "totalsleeptime", "asleeptime", "totalsleep"],
        .timeInBed: ["timeinbed", "totalbedtimeduration", "inbedtime"],
        .deep: ["deepsleepduration", "deepsleeptime", "deepsleep"],
        .light: ["lightsleepduration", "lightsleeptime", "lightsleep"],
        .rem: ["remsleepduration", "remsleeptime", "remsleep"],
        .awake: ["awaketime", "awakeduration", "awake"],
        .latency: ["sleeplatency", "latency", "onsetlatency"],
        .efficiency: ["sleepefficiency", "efficiency"],
        .bedtimeStart: ["bedtimestart", "sleepstart", "bedtimestartdatetime"],
        .bedtimeEnd: ["bedtimeend", "sleepend", "bedtimeenddatetime"],
        .restlessPeriods: ["restlessperiods", "restless", "restlessness"],
        .averageHeartRate: ["averageheartrate", "averagerestingheartrate", "averagehr", "hraverage"],
        .lowestHeartRate: ["lowestrestingheartrate", "lowestheartrate", "lowesthr", "restingheartrate"],
        .hrv: ["averagehrv", "hrv", "rmssd", "hrvaverage"],
        .respiratoryRate: ["respiratoryrate", "averagebreath", "breathaverage"],
        .temperatureDeviation: ["temperaturedeviation", "temperaturedelta", "skintemperaturedeviation"],
        .sleepScore: ["sleepscore", "scoresleep"],
        .readinessScore: ["readinessscore", "scorereadiness"],
        .activityScore: ["activityscore", "scoreactivity"],
        .steps: ["steps", "stepcount"],
        .activeCalories: ["activityburn", "activecalories", "calactive", "activecal"],
        .totalCalories: ["totalburn", "totalcalories", "caltotal"],
        .targetCalories: ["targetcalories", "targetcal"],
        .walkingDistance: ["equivalentwalkingdistance", "walkingequivalent"],
        .inactiveTime: ["inactivetime", "sedentarytime"],
        .restTime: ["resttime", "restingtime"],
        .lowActivityTime: ["lowactivitytime"],
        .mediumActivityTime: ["mediumactivitytime"],
        .highActivityTime: ["highactivitytime"],
        .nonWearTime: ["nonweartime", "nonwear"],
        .inactivityAlerts: ["inactivityalerts", "inactivealerts"],
        .lowActivityMET: ["lowactivitymetminutes"],
        .mediumActivityMET: ["mediumactivitymetminutes"],
        .highActivityMET: ["highactivitymetminutes"],
        .averageMET: ["averagemetminutes", "averagemet"]
    ]

    private static let lookup: [String: Field] = {
        var table: [String: Field] = [:]
        for (field, names) in synonyms {
            for name in names { table[name] = field }
        }
        return table
    }()

    static func normalise(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func canonical(_ columnName: String) -> Field? {
        lookup[normalise(columnName)]
    }

    static func canonicalise(_ record: [String: String]) -> [Field: String] {
        var mapped: [Field: String] = [:]
        for (key, value) in record {
            guard !value.isEmpty, let field = canonical(key) else { continue }
            mapped[field] = value
        }
        return mapped
    }
}

extension Dictionary where Key == Field, Value == String {
    /// Tolerates the decimal comma some locales produce in CSV exports.
    func number(_ field: Field) -> Double? {
        guard let raw = self[field]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return Double(raw) ?? Double(raw.replacingOccurrences(of: ",", with: "."))
    }
}
