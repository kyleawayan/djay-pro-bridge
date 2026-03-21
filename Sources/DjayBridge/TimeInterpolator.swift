import Foundation

public struct TimeInterpolator {
    private var lastElapsedSeconds: Double?
    private var lastRemainingSeconds: Double?
    private var lastUpdateTime: Date
    private var isPlaying: Bool = false
    private var playbackRate: Double = 1.0

    public init() {
        self.lastUpdateTime = Date()
    }

    // MARK: - Update from AX poll

    public mutating func update(
        elapsedTime: String?,
        remainingTime: String?,
        isPlaying: Bool,
        bpmPercent: String?
    ) {
        let newElapsed = elapsedTime.flatMap { Self.parseTime($0) }
        let newRemaining = remainingTime.flatMap { Self.parseTime($0) }

        // If a time field disappears (view change), clear it
        if elapsedTime == nil { lastElapsedSeconds = nil }
        if remainingTime == nil { lastRemainingSeconds = nil }

        // Only reset the baseline when AX reports a new whole-second value.
        // This lets the interpolator accumulate wall-clock delta between ticks.
        let elapsedChanged = newElapsed != nil && newElapsed != lastElapsedSeconds
        let remainingChanged = newRemaining != nil && newRemaining != lastRemainingSeconds

        if elapsedChanged || remainingChanged {
            if let e = newElapsed { lastElapsedSeconds = e }
            if let r = newRemaining { lastRemainingSeconds = r }
            lastUpdateTime = Date()
        }

        // Always update non-time state
        self.isPlaying = isPlaying
        self.playbackRate = Self.parsePlaybackRate(bpmPercent)
    }

    // MARK: - Interpolated values

    public func interpolatedElapsed() -> Double? {
        guard let base = lastElapsedSeconds else { return nil }
        guard isPlaying else { return base }
        let delta = Date().timeIntervalSince(lastUpdateTime) * playbackRate
        return max(0, base + delta)
    }

    public func interpolatedRemaining() -> Double? {
        guard let base = lastRemainingSeconds else { return nil }
        guard isPlaying else { return base }
        let delta = Date().timeIntervalSince(lastUpdateTime) * playbackRate
        return max(0, base - delta)
    }

    // MARK: - Formatting

    /// Formats seconds as MM:SS.m (one decimal place)
    public static func format(_ seconds: Double, negative: Bool = false) -> String {
        let total = abs(seconds)
        let mins = Int(total) / 60
        let secs = Int(total) % 60
        let tenths = Int((total - Double(Int(total))) * 10)
        let sign = negative ? "-" : ""
        return String(format: "%@%02d:%02d.~%d", sign, mins, secs, tenths)
    }

    // MARK: - Parsing

    /// Parses "MM:SS" or "-MM:SS" into positive seconds
    public static func parseTime(_ str: String) -> Double? {
        let cleaned = str.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "")
        let parts = cleaned.split(separator: ":")
        guard parts.count == 2,
              let mins = Double(parts[0]),
              let secs = Double(parts[1]) else { return nil }
        return mins * 60.0 + secs
    }

    /// Parses BPM% string like "3.2%", "-2.0%", "0.0%" into playback rate (e.g. 1.032)
    private static func parsePlaybackRate(_ bpmPercent: String?) -> Double {
        guard let str = bpmPercent else { return 1.0 }
        let cleaned = str.replacingOccurrences(of: "%", with: "")
        guard let pct = Double(cleaned) else { return 1.0 }
        return 1.0 + (pct / 100.0)
    }
}
