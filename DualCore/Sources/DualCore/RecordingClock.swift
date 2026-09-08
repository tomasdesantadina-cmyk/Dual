import Foundation

public enum RecordingClock {
    /// Formats elapsed seconds as HH:MM:SS, matching the on-screen timer pill.
    public static func timecode(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
