import Foundation

public enum TimeFormatting {
    /// A short countdown such as "in 2h 5m" or "in 40s", or "now" once `date` has passed.
    public static func countdown(to date: Date, from now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded(.up))
        guard seconds > 0 else { return "now" }
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3_600
        let minutes = seconds % 3_600 / 60
        if days > 0 { return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d" }
        if hours > 0 { return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h" }
        if minutes > 0 { return "in \(minutes)m" }
        return "in \(seconds)s"
    }
}
