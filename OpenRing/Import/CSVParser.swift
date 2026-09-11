import Foundation

/// RFC 4180-ish CSV reader: quoted fields, escaped quotes, embedded newlines, CRLF or LF.
enum CSVParser {

    static func rows(from text: String) -> [[String]] {
        // Swift treats CR+LF as a single grapheme cluster, so a "\r\n" Character compares
        // equal to neither "\r" nor "\n" and would fall through to the default branch —
        // making every CRLF file, which is what most exporters emit, parse as one field.
        // Normalising line endings up front is simpler than matching every variant below.
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = normalised.makeIterator()
        var pending: Character?

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            // Skip the blank row a trailing newline produces.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"":
                inQuotes = true
            case ",":
                endField()
            case "\n":
                endRow()
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Header row plus dictionaries keyed by the header names.
    static func records(from text: String) -> (headers: [String], records: [[String: String]]) {
        let rows = rows(from: text)
        guard let headers = rows.first else { return ([], []) }
        let records = rows.dropFirst().map { row -> [String: String] in
            var record: [String: String] = [:]
            for (index, header) in headers.enumerated() where index < row.count {
                record[header] = row[index]
            }
            return record
        }
        return (headers, records)
    }
}
