//
//  FuelCSV.swift
//  ReTripper
//
//  Import and export fuel fills as CSV. Understands the Fuelio export format
//  (sections marked with "## ...", the fills live under "## Log") as well as
//  ReTripper's own export, which uses the same Log column names so files move
//  between the two apps. Columns are matched by name, not position, so small
//  differences between exports still import.
//

import Foundation

enum FuelCSV {

    // MARK: - Export

    /// ReTripper's CSV. Column names match Fuelio's Log section so the file is
    /// importable by both apps. Sorted oldest-first (by odometer).
    static func export(_ logs: [FuelLog], odometerUnit: String = "km") -> String {
        let df = Self.exportDateFormatter
        var lines = ["\"Date\",\"Odo (\(odometerUnit))\",\"Fuel (l)\",\"Full\",\"Price\",\"VolumePrice\",\"Notes\""]
        for log in logs.sorted(by: { $0.odometer < $1.odometer }) {
            let ppl = log.pricePerLiter ?? (log.liters > 0 ? log.totalCost / log.liters : 0)
            let fields = [
                df.string(from: log.date),
                trimNumber(log.odometer),
                trimNumber(log.liters),
                log.isFullTank ? "1" : "0",
                trimNumber(log.totalCost),
                trimNumber(ppl),
                log.notes
            ]
            lines.append(fields.map(quote).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Import

    /// Parse fuel fills out of CSV text. Returns an empty array if no recognisable
    /// fuel-log table is found.
    static func parse(_ text: String) -> [FuelLog] {
        let rows = text
            .components(separatedBy: .newlines)
            .map { parseLine($0) }

        guard let headerIndex = rows.firstIndex(where: isLogHeader) else { return [] }
        let columns = ColumnMap(header: rows[headerIndex].map(normalize))
        guard columns.odometer != nil, columns.liters != nil else { return [] }

        var logs: [FuelLog] = []
        for row in rows[(headerIndex + 1)...] {
            if row.first?.trimmingCharacters(in: .whitespaces).hasPrefix("##") == true { break }
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            if let log = makeLog(row, columns) { logs.append(log) }
        }
        return logs
    }

    // MARK: - Column mapping

    private struct ColumnMap {
        let date: Int?
        let odometer: Int?
        let liters: Int?
        let full: Int?
        let totalCost: Int?
        let pricePerLiter: Int?
        let notes: Int?

        init(header: [String]) {
            func find(_ predicate: (String) -> Bool) -> Int? { header.firstIndex(where: predicate) }
            date = find { $0 == "date" }
            odometer = find { $0.hasPrefix("odo") }
            liters = find { $0.hasPrefix("fuel") || $0.contains("liter") || $0.contains("litre") }
            full = find { $0 == "full" }
            // Price-per-litre is the more specific match, so a plain "price" maps to the total.
            pricePerLiter = find { $0 == "volumeprice" || $0.contains("per l") || $0.contains("price/l") || $0.contains("priceperlit") }
            totalCost = find { $0 == "price" || $0.contains("total") }
            notes = find { $0.hasPrefix("note") }
        }
    }

    private static func isLogHeader(_ row: [String]) -> Bool {
        let h = row.map(normalize)
        let hasOdo = h.contains { $0.hasPrefix("odo") }
        let hasFuel = h.contains { $0.hasPrefix("fuel") || $0.contains("liter") || $0.contains("litre") }
        let hasDate = h.contains { $0 == "date" }
        return hasOdo && hasFuel && hasDate
    }

    private static func makeLog(_ row: [String], _ col: ColumnMap) -> FuelLog? {
        func value(_ index: Int?) -> String? {
            guard let index, index < row.count else { return nil }
            let v = row[index].trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }

        guard let odoStr = value(col.odometer), let odometer = Double(odoStr),
              let litStr = value(col.liters), let liters = Double(litStr), liters > 0 else { return nil }

        let total = value(col.totalCost).flatMap(Double.init)
        let ppl = value(col.pricePerLiter).flatMap(Double.init)
        let fullFlag = (value(col.full) ?? "1").lowercased()
        let isFull = fullFlag == "1" || fullFlag == "true" || fullFlag == "yes"
        let notes = value(col.notes) ?? ""
        let date = value(col.date).flatMap(parseDate) ?? Date()

        let totalCost = total ?? (ppl.map { $0 * liters } ?? 0)
        let pricePerLiter = ppl ?? ((total ?? 0) > 0 && liters > 0 ? (total ?? 0) / liters : nil)

        return FuelLog(date: date, odometer: odometer, liters: liters, totalCost: totalCost,
                       isFullTank: isFull, notes: notes, pricePerLiter: pricePerLiter)
    }

    // MARK: - Low-level helpers

    /// Split one CSV line into fields, honouring double-quoted fields and ""
    /// escaped quotes. Returns fields with surrounding quotes removed.
    static func parseLine(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": fields.append(field); field = ""
                default: field.append(c)
                }
            }
            i += 1
        }
        fields.append(field)
        return fields
    }

    private static func normalize(_ field: String) -> String {
        field.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func trimNumber(_ d: Double) -> String {
        d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.2f", d)
    }

    private static let exportDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private static func parseDate(_ s: String) -> Date? {
        let formats = ["yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "dd/MM/yyyy", "MM/dd/yyyy"]
        for f in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}
