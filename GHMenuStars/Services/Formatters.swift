import Foundation

extension NumberFormatter {
    static let menuInteger: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

extension RelativeDateTimeFormatter {
    static let menu: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

enum RepoDeltaFormatter {
    static func metricLine(label: String, value: Int?, delta: Int?) -> String {
        let formattedValue: String
        if let value {
            formattedValue = NumberFormatter.menuInteger.string(from: NSNumber(value: value)) ?? "\(value)"
        } else {
            formattedValue = "--"
        }
        guard let delta, delta > 0 else { return "\(label) \(formattedValue)" }
        return "\(label) \(formattedValue)  +\(NumberFormatter.menuInteger.string(from: NSNumber(value: delta)) ?? "\(delta)")"
    }
}

