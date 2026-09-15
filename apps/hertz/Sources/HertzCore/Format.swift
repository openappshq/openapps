import Foundation

/// Readout formatting shared by the dashboard, the menu bar, the diagnostic
/// report and the verifier, so a value reads the same everywhere it appears.
nonisolated public enum Format {
    /// Bytes as KB, MB or GB with as few digits as the size allows.
    public static func bytes(_ bytes: UInt64) -> String {
        if bytes < 1_048_576 {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    /// Whole gigabytes, for disk totals.
    public static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.0f GB", Double(bytes) / 1_073_741_824)
    }

    /// Throughput as KB/s or MB/s. Below a kilobyte per second reads as 0.
    public static func rate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb >= 1024 { return String(format: "%.1f MB/s", kb / 1024) }
        if kb >= 1 { return String(format: "%.0f KB/s", kb) }
        return "0 KB/s"
    }

    /// Minutes as `1h 05m` or `45m`; negative means unknown.
    public static func minutes(_ minutes: Int) -> String {
        if minutes < 0 { return "—" }
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : "\(m)m"
    }

    /// Seconds of uptime as days and hours, hours and minutes, or minutes.
    public static func duration(seconds: Int) -> String {
        let secs = max(0, seconds)
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// A percentage with the given number of decimals and a percent sign.
    public static func percent(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", value)
    }
}
