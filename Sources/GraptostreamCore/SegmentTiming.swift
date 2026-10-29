// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// When the speech of the current segment was first heard, in seconds of the
/// analysis session. A provisional result's time range runs from the end of the
/// previous segment, so it counts the silence before the speech, and its word
/// times do too (measured on 2026-10-29: after 40 s of silence the first word was
/// timed at 0 s; the final placed it at 39.1 s). The end of the first provisional
/// range that holds words is the earliest reliable point: at most about two
/// seconds after the speech began. Provisional segments start there and the
/// length limit is measured from there, so that silence alone never makes a
/// segment too long. A final carries its own, exact range.
public struct SegmentTiming: Sendable, Equatable {
    public private(set) var firstHeard: Double?

    public init() {}

    /// Records one provisional result and returns the start to publish with it.
    public mutating func provisional(rangeEnd: Double, hasWords: Bool) -> Double {
        if firstHeard == nil, hasWords { firstHeard = rangeEnd }
        return firstHeard ?? rangeEnd
    }

    /// Whether a provisional result ending at `end` has run past `limit` seconds
    /// since the speech was first heard. False until then.
    public func isTooLong(end: Double, limit: Double) -> Bool {
        guard let firstHeard else { return false }
        return end - firstHeard > limit
    }

    /// Ends the segment; the next result begins a new one.
    public mutating func reset() { firstHeard = nil }
}
