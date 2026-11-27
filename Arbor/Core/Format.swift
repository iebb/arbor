import Foundation

/// Explorer-style formatting for sizes and dates.
enum Format {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter
    }()

    static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        return dateFormatter.string(from: date)
    }

    static func longDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return longDateFormatter.string(from: date)
    }

    static func number(_ value: Int64) -> String {
        grouped.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// The Details view "Size" column: whole kilobytes rounded up ("0 KB", "1 KB", "1,234 KB").
    static func kilobytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "" }
        let kb = (max(bytes, 0) + 1023) / 1024
        return "\(number(kb)) KB"
    }

    /// Status bar / Properties sizes: three significant digits in binary units ("1.50 KB", "12.3 MB").
    static func bytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let text: String
        if value < 10 {
            text = String(format: "%.2f", (value * 100).rounded(.down) / 100)
        } else if value < 100 {
            text = String(format: "%.1f", (value * 10).rounded(.down) / 10)
        } else {
            text = String(format: "%.0f", value.rounded(.down))
        }
        return "\(text) \(units[unit])"
    }

    /// "1.20 MB (1,258,291 bytes)" as in the Properties window.
    static func bytesWithExact(_ bytes: Int64) -> String {
        "\(Format.bytes(bytes)) (\(number(bytes)) bytes)"
    }

    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(number(Int64(count))) items"
    }
}
