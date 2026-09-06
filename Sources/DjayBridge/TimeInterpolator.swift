import Foundation

public struct TimeInterpolator {
    private var lastElapsedSeconds: Double?
    private var lastRemainingSeconds: Double?
    private var lastUpdateTime: Date
    private var isPlaying: Bool = false
    private var playbackRate: Double = 1.0

    /// Cap on how far interpolation may run past the last AX-confirmed value.
    /// A stalled poll (AX blocked) would otherwise let the clock free-run
    /// unbounded; this freezes it a little past the last real tick instead.
    static let maxInterpolationLead: Double = 1.5

    /// When a clean one-second tick lets us predict djay's own tick cadence,
    /// only trust that prediction if it lands within this margin of the actual
    /// read time; otherwise a missed poll or seek is assumed and we resync.
    static let phaseLockTolerance: Double = 0.15

    public init() {
        self.lastUpdateTime = Date()
    }

    // MARK: - Update from AX poll

    /// - Parameter sampleTime: the wall-clock instant the AX time field was
    ///   read. Passing the read time (not "now" after the whole scan) removes
    ///   the accessibility-scan latency from the interpolation baseline.
    public mutating func update(
        elapsedTime: String?,
        remainingTime: String?,
        isPlaying: Bool,
        bpmPercent: String?,
        sampleTime: Date
    ) {
        let newElapsed = elapsedTime.flatMap { Self.parseTime($0) }
        let newRemaining = remainingTime.flatMap { Self.parseTime($0) }

        // If a time field disappears (view change), clear it
        if elapsedTime == nil { lastElapsedSeconds = nil }
        if remainingTime == nil { lastRemainingSeconds = nil }

        let rate = Self.parsePlaybackRate(bpmPercent)

        // Only reset the baseline when AX reports a new whole-second value.
        // This lets the interpolator accumulate wall-clock delta between ticks.
        let elapsedChanged = newElapsed != nil && newElapsed != lastElapsedSeconds
        let remainingChanged = newRemaining != nil && newRemaining != lastRemainingSeconds

        if elapsedChanged || remainingChanged {
            // A clean ±1s step means djay crossed a whole second exactly once
            // since the last confirmed value. djay's crossings are evenly
            // spaced at 1/rate wall-seconds, so predict this crossing from the
            // last one rather than stamping the jittery moment we detected it.
            let cleanElapsedTick = elapsedChanged && lastElapsedSeconds != nil
                && newElapsed == lastElapsedSeconds! + 1
            let cleanRemainingTick = remainingChanged && lastRemainingSeconds != nil
                && newRemaining == lastRemainingSeconds! - 1

            var baseline = sampleTime
            if isPlaying && rate > 0 && (cleanElapsedTick || cleanRemainingTick) {
                let predicted = lastUpdateTime.addingTimeInterval(1.0 / rate)
                if abs(predicted.timeIntervalSince(sampleTime)) <= Self.phaseLockTolerance {
                    baseline = predicted
                }
            }

            if let e = newElapsed { lastElapsedSeconds = e }
            if let r = newRemaining { lastRemainingSeconds = r }
            lastUpdateTime = baseline
        }

        // Always update non-time state
        self.isPlaying = isPlaying
        self.playbackRate = rate
    }

    // MARK: - Interpolated values

    private func interpolationAdvance() -> Double {
        let raw = Date().timeIntervalSince(lastUpdateTime) * playbackRate
        return min(raw, Self.maxInterpolationLead)
    }

    public func interpolatedElapsed() -> Double? {
        guard let base = lastElapsedSeconds else { return nil }
        guard isPlaying else { return base }
        return max(0, base + interpolationAdvance())
    }

    public func interpolatedRemaining() -> Double? {
        guard let base = lastRemainingSeconds else { return nil }
        guard isPlaying else { return base }
        return max(0, base - interpolationAdvance())
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
