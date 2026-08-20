import Foundation

/// Storage vendors and macOS both quote decimal MB, so the app does too —
/// mixing MB (10^6) and MiB (2^20) is how a "480 MB/s" drive appears to be
/// running at 458 MB/s for no reason.
enum Format {

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1000 else { return "0" }
        let mb = bytesPerSecond / 1_000_000
        if mb >= 1000 { return String(format: "%.2f", mb / 1000) }
        if mb >= 100  { return String(format: "%.0f", mb) }
        if mb >= 10   { return String(format: "%.1f", mb) }
        if mb >= 1    { return String(format: "%.2f", mb) }
        return String(format: "%.0f", bytesPerSecond / 1000)
    }

    static func rateUnit(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1000 else { return "MB/s" }
        let mb = bytesPerSecond / 1_000_000
        if mb >= 1000 { return "GB/s" }
        if mb >= 1    { return "MB/s" }
        return "KB/s"
    }

    static func rateFull(_ bytesPerSecond: Double) -> String {
        "\(rate(bytesPerSecond)) \(rateUnit(bytesPerSecond))"
    }

    /// Fixed width on purpose. A variable-width status item shifts everything
    /// to its right in the menu bar every time a digit changes.
    static func menuBar(_ bytesPerSecond: Double) -> String {
        let mb = bytesPerSecond / 1_000_000
        if mb >= 1000 { return String(format: "%6.2f GB/s", mb / 1000) }
        return String(format: "%6.1f MB/s", mb)
    }

    static func mbps(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        if value >= 1000 { return String(format: "%.2f GB/s", value / 1000) }
        if value >= 100 { return String(format: "%.0f MB/s", value) }
        return String(format: "%.1f MB/s", value)
    }

    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return i <= 1 ? "\(Int(v)) \(units[i])" : String(format: "%.1f %@", v, units[i])
    }

    static func iops(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        if value >= 10_000 { return String(format: "%.0fk", value / 1000) }
        return String(format: "%.0f", value)
    }

    static func latency(_ micros: Double?) -> String {
        guard let micros, micros.isFinite, micros > 0 else { return "—" }
        if micros >= 1000 { return String(format: "%.1f ms", micros / 1000) }
        return String(format: "%.0f µs", micros)
    }

    /// Chart axis ticks. Below 10 the ticks are fractional, and truncating
    /// them to Int renders an axis reading "0 / 0 / 1".
    static func axisTick(_ value: Double) -> String {
        if value >= 1000 { return String(format: "%.1fG", value / 1000) }
        if value < 10 { return String(format: "%.1f", value) }
        return "\(Int(value))"
    }

    /// Queue depth is a count of in-flight requests, not a percentage — one
    /// decimal is enough and the unit is deliberately absent.
    static func queueDepth(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        return String(format: "%.1f", value)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", max(0, min(1.5, fraction)) * 100)
    }
}
