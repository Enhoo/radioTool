import Foundation

enum TimeFormat {
    static func clock(_ seconds: TimeInterval, tenths: Bool = false) -> String {
        let safe = max(0, seconds)
        let totalTenths = Int((safe * 10).rounded(.down))
        let tenth = totalTenths % 10
        let totalSeconds = totalTenths / 10
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        if tenths {
            return String(format: "%02d:%02d.%d", minutes, secs, tenth)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
