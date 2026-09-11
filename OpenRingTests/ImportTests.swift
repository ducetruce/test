import XCTest
@testable import OpenRing

final class CSVParserTests: XCTestCase {
    func testParsesQuotedFieldsAndEmbeddedCommas() {
        let rows = CSVParser.rows(from: "a,b,c\n1,\"two, still two\",3\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last, ["1", "two, still two", "3"])
    }

    func testHandlesEscapedQuotesAndCRLF() {
        let rows = CSVParser.rows(from: "h\r\n\"say \"\"hi\"\"\"\r\n")
        XCTAssertEqual(rows.last, ["say \"hi\""])
    }

    func testRecordsAreKeyedByHeader() {
        let parsed = CSVParser.records(from: "date,steps\n2026-01-02,1234\n")
        XCTAssertEqual(parsed.headers, ["date", "steps"])
        XCTAssertEqual(parsed.records.first?["steps"], "1234")
    }
}

final class FieldMappingTests: XCTestCase {
    func testColumnNameSpellingsAllCanonicalise() {
        XCTAssertEqual(Field.canonical("Total Sleep Duration"), .totalSleep)
        XCTAssertEqual(Field.canonical("total_sleep_duration"), .totalSleep)
        XCTAssertEqual(Field.canonical("totalSleepDuration"), .totalSleep)
        XCTAssertEqual(Field.canonical("Average HRV"), .hrv)
        XCTAssertEqual(Field.canonical("Activity Burn"), .activeCalories)
        XCTAssertNil(Field.canonical("Something Oura Invented Later"))
    }

    func testDecimalCommaIsAccepted() {
        let fields: [Field: String] = [.hrv: "62,5"]
        XCTAssertEqual(fields.number(.hrv) ?? 0, 62.5, accuracy: 0.001)
    }
}

final class ZipArchiveTests: XCTestCase {
    /// Builds a stored (uncompressed) ZIP by hand so the central-directory walk is exercised
    /// without needing a binary fixture in the repo.
    private func makeZip(entries: [(name: String, contents: String)]) -> Data {
        var output = Data()
        var directory = Data()
        var offsets: [Int] = []

        func append16(_ value: Int, to data: inout Data) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }
        func append32(_ value: Int, to data: inout Data) {
            append16(value & 0xFFFF, to: &data)
            append16((value >> 16) & 0xFFFF, to: &data)
        }

        for entry in entries {
            offsets.append(output.count)
            let name = Array(entry.name.utf8)
            let body = Array(entry.contents.utf8)

            append32(0x0403_4B50, to: &output)
            append16(20, to: &output)          // version needed
            append16(0, to: &output)           // flags
            append16(0, to: &output)           // method: stored
            append16(0, to: &output)           // time
            append16(0, to: &output)           // date
            append32(0, to: &output)           // crc32 (not validated by the reader)
            append32(body.count, to: &output)  // compressed size
            append32(body.count, to: &output)  // uncompressed size
            append16(name.count, to: &output)
            append16(0, to: &output)           // extra length
            output.append(contentsOf: name)
            output.append(contentsOf: body)
        }

        for (index, entry) in entries.enumerated() {
            let name = Array(entry.name.utf8)
            let body = Array(entry.contents.utf8)
            append32(0x0201_4B50, to: &directory)
            append16(20, to: &directory)       // version made by
            append16(20, to: &directory)       // version needed
            append16(0, to: &directory)
            append16(0, to: &directory)        // method
            append16(0, to: &directory)
            append16(0, to: &directory)
            append32(0, to: &directory)        // crc
            append32(body.count, to: &directory)
            append32(body.count, to: &directory)
            append16(name.count, to: &directory)
            append16(0, to: &directory)        // extra
            append16(0, to: &directory)        // comment
            append16(0, to: &directory)        // disk
            append16(0, to: &directory)        // internal attrs
            append32(0, to: &directory)        // external attrs
            append32(offsets[index], to: &directory)
            directory.append(contentsOf: name)
        }

        let directoryOffset = output.count
        output.append(directory)
        append32(0x0605_4B50, to: &output)
        append16(0, to: &output)
        append16(0, to: &output)
        append16(entries.count, to: &output)
        append16(entries.count, to: &output)
        append32(directory.count, to: &output)
        append32(directoryOffset, to: &output)
        append16(0, to: &output)
        return output
    }

    func testReadsStoredEntries() throws {
        let zip = makeZip(entries: [("trends.csv", "date,steps\n2026-01-02,900\n"), ("notes.txt", "hello")])
        let entries = try ZipArchive.entries(in: zip)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.name, "trends.csv")
        XCTAssertEqual(entries.last.map { String(decoding: $0.data, as: UTF8.self) }, "hello")
    }

    func testRejectsNonZipData() {
        XCTAssertThrowsError(try ZipArchive.entries(in: Data("not a zip at all".utf8)))
    }
}

final class ExportImporterTests: XCTestCase {
    private func write(_ contents: String, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testImportsATrendsStyleCSV() throws {
        let csv = """
        date,Total Sleep Duration,REM Sleep Duration,Deep Sleep Duration,Light Sleep Duration,Awake Time,Sleep Efficiency,Sleep Latency,Lowest Resting Heart Rate,Average HRV,Temperature Deviation,Sleep Score,Readiness Score,Activity Score,Steps,Activity Burn,Total Burn,Inactive Time
        2026-01-02,27000,5400,4320,17280,1500,92,900,51,64,-0.12,84,79,77,10432,480,2350,25200
        """
        let url = try write(csv, name: "trends-test.csv")
        var database = Database()
        let report = try ExportImporter.importFile(at: url, into: &database)

        XCTAssertEqual(report.sleepImported, 1)
        XCTAssertEqual(report.activityImported, 1)
        XCTAssertEqual(report.readinessImported, 1)
        XCTAssertTrue(report.unmappedColumns.isEmpty, "unexpected: \(report.unmappedColumns)")

        let day = Day(year: 2026, month: 1, day: 2)
        let night = try XCTUnwrap(database.mainSleep(on: day))
        XCTAssertEqual(night.totalSleep, 27000)
        XCTAssertEqual(night.rem, 5400)
        XCTAssertEqual(night.lowestHeartRate, 51)
        XCTAssertEqual(database.activityDay(day)?.steps, 10432)
        XCTAssertEqual(database.readinessDay(day)?.temperatureDeviation ?? 0, -0.12, accuracy: 0.0001)
    }

    func testDurationsGivenInMinutesAreScaled() throws {
        let csv = """
        date,Total Sleep Duration,Deep Sleep Duration
        2026-02-03,450,72
        """
        let url = try write(csv, name: "minutes-test.csv")
        var database = Database()
        _ = try ExportImporter.importFile(at: url, into: &database)

        let night = try XCTUnwrap(database.mainSleep(on: Day(year: 2026, month: 2, day: 3)))
        XCTAssertEqual(night.totalSleep, 450 * 60, "450 should read as minutes, not seconds")
        XCTAssertEqual(night.deep, 72 * 60)
    }

    func testApiDataIsNotOverwrittenByAnExport() throws {
        let day = Day(year: 2026, month: 3, day: 4)
        var database = Database()
        database.merge(sleep: [Fixtures.night(day: day, hours: 8)])

        let csv = "date,Total Sleep Duration\n2026-03-04,10800\n"
        let url = try write(csv, name: "conflict-test.csv")
        let report = try ExportImporter.importFile(at: url, into: &database)

        XCTAssertEqual(report.sleepImported, 0)
        XCTAssertEqual(report.skippedExisting, 1)
        XCTAssertEqual(database.mainSleep(on: day)?.totalSleep, 8 * 3600, "the synced night should win")
    }

    func testUnrecognisedColumnsAreReported() throws {
        let csv = "date,Steps,Mystery Column\n2026-04-05,500,7\n"
        let url = try write(csv, name: "unknown-test.csv")
        var database = Database()
        let report = try ExportImporter.importFile(at: url, into: &database)
        XCTAssertTrue(report.unmappedColumns.contains("Mystery Column"))
    }

    func testJSONExportShapeIsAccepted() throws {
        let json = """
        {"sleep":[{"day":"2026-05-06","total_sleep_duration":25200,"rem_sleep_duration":5000,"average_hrv":58}]}
        """
        let url = try write(json, name: "export-test.json")
        var database = Database()
        let report = try ExportImporter.importFile(at: url, into: &database)
        XCTAssertEqual(report.sleepImported, 1)
        XCTAssertEqual(database.mainSleep(on: Day(year: 2026, month: 5, day: 6))?.averageHRV, 58)
    }

    func testMeaninglessFileIsRejected() throws {
        let url = try write("nothing,useful\n1,2\n", name: "junk-test.csv")
        var database = Database()
        XCTAssertThrowsError(try ExportImporter.importFile(at: url, into: &database))
    }
}

final class EndpointReportTests: XCTestCase {
    private func report(_ days: [Day], requestedTo: Day) -> EndpointReport {
        EndpointReport(endpoint: "sleep", requestedFrom: requestedTo.adding(days: -14),
                       requestedTo: requestedTo, received: days.count,
                       newestDay: days.max(), missingToday: !days.contains(requestedTo))
    }

    /// The whole point of the report: separating "Oura had nothing" from "we lost it".
    func testFlagsWhenTheNewestRequestedDayCameBackEmpty() {
        let today = Day(year: 2026, month: 9, day: 10)
        let short = report(Day.range(from: today.adding(days: -5), through: today.adding(days: -1)), requestedTo: today)
        XCTAssertTrue(short.missingToday)
        XCTAssertEqual(short.newestDay, today.adding(days: -1))

        let complete = report(Day.range(from: today.adding(days: -5), through: today), requestedTo: today)
        XCTAssertFalse(complete.missingToday)
        XCTAssertEqual(complete.newestDay, today)
    }

    func testEmptyResponseIsReportedAsMissing() {
        let today = Day(year: 2026, month: 9, day: 10)
        let none = report([], requestedTo: today)
        XCTAssertTrue(none.missingToday)
        XCTAssertNil(none.newestDay)
        XCTAssertEqual(none.received, 0)
    }

    func testReportSurvivesADatabaseRoundTrip() throws {
        var database = Database()
        database.lastSyncReports = [report([Day(year: 2026, month: 9, day: 9)], requestedTo: Day(year: 2026, month: 9, day: 10))]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(Database.self, from: try encoder.encode(database))
        XCTAssertEqual(restored.lastSyncReports.first?.missingToday, true)
        XCTAssertEqual(restored.lastSyncReports.first?.endpoint, "sleep")
    }
}

final class EndpointReportFlaggingTests: XCTestCase {
    private func make(_ days: [Day], to: Day, isDaily: Bool) -> EndpointReport {
        EndpointReport(endpoint: "e", requestedFrom: to.adding(days: -30), requestedTo: to,
                       received: days.count, newestDay: days.max(), isDaily: isDaily,
                       failure: nil, missingToday: isDaily && !days.contains(to))
    }

    /// Workouts are sporadic; flagging every quiet week trains the reader to ignore the flag.
    func testEventBasedEndpointsAreNeverFlaggedForAGap() {
        let today = Day(year: 2026, month: 9, day: 10)
        let stale = make([Day(year: 2026, month: 9, day: 2)], to: today, isDaily: false)
        XCTAssertFalse(stale.missingToday)
    }

    func testDailyEndpointsStillFlagAMissingToday() {
        let today = Day(year: 2026, month: 9, day: 10)
        XCTAssertTrue(make([Day(year: 2026, month: 9, day: 9)], to: today, isDaily: true).missingToday)
        XCTAssertFalse(make([today], to: today, isDaily: true).missingToday)
    }

    /// The most alarming case was previously the quietest: no records, so no date line.
    func testAnEmptyEndpointIsFlaggedRegardlessOfKind() {
        let today = Day(year: 2026, month: 9, day: 10)
        XCTAssertTrue(make([], to: today, isDaily: false).returnedNothing)
        XCTAssertTrue(make([], to: today, isDaily: true).returnedNothing)
        XCTAssertFalse(make([today], to: today, isDaily: true).returnedNothing)
    }
}
