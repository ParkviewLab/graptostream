// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Synchronization
import Testing
@testable import GraptostreamCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

private func part(_ id: String, _ state: Segment.State, _ text: String, from: Double, to: Double) -> Segment {
    Segment(seg: id, state: state, start: at(from), end: at(to), text: text, source: "mic")
}

@Suite struct SentenceJoining {
    /// The measured case: "Peabody, I'm planning a trip to Boston. What will the weather be?"
    @Test func sentencesWithoutAPauseAreJoinedUnderTheFirstId() {
        var j = SentenceJoiner(window: 0.333)
        let first = part("1", .final, "Peabody, I'm planning a trip to Boston.", from: 0, to: 3.3)
        #expect(j.receive(first, at: at(3.9)).isEmpty, "the final is held")
        #expect(j.deadline == at(3.9).addingTimeInterval(0.333))
        // The next sentence's first word arrives in the same instant.
        let shown = j.receive(part("2", .provisional, "what", from: 3.3, to: 3.7), at: at(3.9))
        #expect(shown.map(\.seg) == ["1"])
        #expect(shown.first?.state == .provisional)
        #expect(shown.first?.text == "Peabody, I'm planning a trip to Boston. what")
        #expect(j.deadline == nil, "held until that sentence is final")
        #expect(j.flush(at: at(10)).isEmpty)
        #expect(j.receive(part("2", .final, "What will the weather be?", from: 3.3, to: 4.6), at: at(4.9)).isEmpty)
        #expect(j.flush(at: at(5.1)).isEmpty, "the window is open again")
        let out = j.flush(at: at(4.9).addingTimeInterval(0.333))
        #expect(out.count == 1)
        #expect(out[0].seg == "1")
        #expect(out[0].state == .final)
        #expect(out[0].text == "Peabody, I'm planning a trip to Boston. What will the weather be?")
        #expect(out[0].start == at(0) && out[0].end == at(4.6))
        #expect(j.deadline == nil)
    }

    @Test func aFinalFollowedByAPauseIsReleasedWhenTheWindowPasses() {
        var j = SentenceJoiner(window: 0.333)
        let s = part("7", .final, "What time is it?", from: 0, to: 1.5)
        #expect(j.receive(s, at: at(2)).isEmpty)
        #expect(j.flush(at: at(2.2)).isEmpty)
        #expect(j.flush(at: at(2).addingTimeInterval(0.333)) == [s])
        // Speech after the pause starts a segment of its own.
        let next = part("8", .provisional, "and", from: 4, to: 4.2)
        #expect(j.receive(next, at: at(4.3)) == [next])
    }

    @Test func provisionalTextPassesThroughWhileNothingIsHeld() {
        var j = SentenceJoiner(window: 0.333)
        let p = part("3", .provisional, "Peabody", from: 0, to: 0.5)
        #expect(j.receive(p, at: at(0.6)) == [p])
    }

    @Test func aWindowOfZeroChangesNothing() {
        var j = SentenceJoiner(window: 0)
        let f = part("4", .final, "One.", from: 0, to: 1)
        let g = part("5", .final, "Two.", from: 1, to: 2)
        #expect(j.receive(f, at: at(1.2)) == [f])
        #expect(j.receive(g, at: at(2.2)) == [g])
    }

    @Test func drainingReleasesWhatIsHeldAsFinal() {
        var j = SentenceJoiner(window: 0.333)
        _ = j.receive(part("6", .final, "First.", from: 0, to: 1), at: at(1.1))
        _ = j.receive(part("7", .provisional, "second", from: 1, to: 1.4), at: at(1.5))
        let out = j.drain()
        #expect(out.map(\.text) == ["First. second"])
        #expect(out.first?.state == .final)
        #expect(j.drain().isEmpty)
    }

    @Test func anEmptyFinalAddsNothing() {
        var j = SentenceJoiner(window: 0.333)
        _ = j.receive(part("1", .final, "Hello.", from: 0, to: 1), at: at(1.1))
        _ = j.receive(part("2", .provisional, "uh", from: 1, to: 1.2), at: at(1.2))
        _ = j.receive(part("2", .final, "", from: 1, to: 1.3), at: at(1.4))
        #expect(j.flush(at: at(2)).map(\.text) == ["Hello."])
    }

    @Test func theQueueReleasesOnItsOwnWhenTheWindowPasses() async throws {
        let q = SentenceJoinQueue(window: 0.05)
        let got = Mutex<[Segment]>([])
        q.onSegment = { s in got.withLock { $0.append(s) } }
        q.receive(part("1", .final, "One.", from: 0, to: 1))
        q.receive(part("2", .provisional, "two", from: 1, to: 1.2))
        q.receive(part("2", .final, "Two.", from: 1, to: 1.5))
        #expect(got.withLock { $0.map(\.state) } == [.provisional], "only the joined provisional text so far")
        try await Task.sleep(for: .milliseconds(300))
        #expect(got.withLock { $0.filter { $0.state == .final }.map(\.text) } == ["One. Two."])
    }
}
