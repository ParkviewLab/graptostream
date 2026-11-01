// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Joins sentences spoken without a pause into one utterance.
///
/// Apple's engine, with fast results, ends a segment at each sentence it recognises,
/// pause or none, so a two-sentence question reached its app as two finals, and only
/// the first carried the spoken name. Measured on 2026-10-31: when speech runs on, the
/// next segment's first provisional words arrive in the same millisecond as the
/// previous final; after a real pause nothing arrives for a second or more.
///
/// So a final is held for `window` seconds. If a new segment's provisional text arrives
/// within it, the held final keeps waiting, the new words are shown as provisional text
/// of the held segment, and the new segment's final is joined on, opening the window
/// again. A window that passes with nothing new releases the joined final. A window of
/// zero passes every segment through unchanged.
public struct SentenceJoiner: Sendable {
    public var window: TimeInterval
    /// A final waiting for its window to pass, with anything joined to it.
    private var held: Segment?
    /// The id of a later segment being joined to `held`, while it is still provisional,
    /// and the joined text shown for it so far.
    private var joining: String?
    private var shown: Segment?
    /// When the held final is released, unless more speech arrives first.
    public private(set) var deadline: Date?

    public init(window: TimeInterval) {
        self.window = window
    }

    /// What to publish now for a segment from the recogniser, received at `now`.
    public mutating func receive(_ s: Segment, at now: Date) -> [Segment] {
        guard window > 0 else { return drain() + [s] }
        guard let h = held else {
            if s.state == .provisional { return [s] }
            held = s
            deadline = now.addingTimeInterval(window)
            return []
        }
        switch s.state {
        case .provisional:
            // Speech ran on: keep holding until this segment's final arrives.
            joining = s.seg
            deadline = nil
            let joined = Self.join(h, s, as: .provisional)
            shown = joined
            return [joined]
        case .final:
            held = Self.join(h, s, as: .final)
            joining = nil
            shown = nil
            deadline = now.addingTimeInterval(window)
            return []
        }
    }

    /// The held final, if its window has passed by `now`.
    public mutating func flush(at now: Date) -> [Segment] {
        guard let d = deadline, now >= d, joining == nil else { return [] }
        return drain()
    }

    /// Whatever is held, at once: when listening stops, or joining is switched off.
    public mutating func drain() -> [Segment] {
        defer {
            held = nil
            joining = nil
            shown = nil
            deadline = nil
        }
        // Part-way through a join, the words shown so far are kept.
        guard var h = (joining != nil ? shown : nil) ?? held else { return [] }
        h.state = .final
        return [h]
    }

    /// `later` joined onto `first`, under `first`'s id and start.
    static func join(_ first: Segment, _ later: Segment, as state: Segment.State) -> Segment {
        let text = [first.text, later.text]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return Segment(seg: first.seg, state: state, start: first.start, end: max(first.end, later.end),
                       text: text, source: first.source ?? later.source)
    }
}

/// A `SentenceJoiner` for the app: thread-safe, releasing a held final when its window
/// passes. Segments go to `onSegment` in the order they are released.
public final class SentenceJoinQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var joiner: SentenceJoiner
    private var pending: DispatchWorkItem?
    public var onSegment: (@Sendable (Segment) -> Void)?

    public init(window: TimeInterval) {
        joiner = SentenceJoiner(window: window)
    }

    public var window: TimeInterval {
        get { lock.withLock { joiner.window } }
        set {
            lock.withLock {
                joiner.window = newValue
                if newValue <= 0 { emit(joiner.drain()) }
                schedule()
            }
        }
    }

    public func receive(_ s: Segment) {
        lock.withLock {
            emit(joiner.receive(s, at: Date()))
            schedule()
        }
    }

    /// Releases whatever is held, at once.
    public func drain() {
        lock.withLock {
            emit(joiner.drain())
            schedule()
        }
    }

    private func flush() {
        lock.withLock {
            emit(joiner.flush(at: Date()))
            schedule()
        }
    }

    /// Called with the lock held, so that segments go out in order.
    private func emit(_ segments: [Segment]) {
        for s in segments { onSegment?(s) }
    }

    /// Called with the lock held.
    private func schedule() {
        pending?.cancel()
        pending = nil
        guard let d = joiner.deadline else { return }
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0, d.timeIntervalSinceNow), execute: work)
    }
}
