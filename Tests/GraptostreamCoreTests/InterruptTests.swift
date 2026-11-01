// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import GraptostreamCore

private let names = [SpokenName(name: "Aristotle", app: "peabody"), SpokenName(name: "Fred", app: "scrinotia")]

private func heard(_ id: String, _ state: Segment.State, _ text: String) -> Segment {
    Segment(seg: id, state: state, start: Date(timeIntervalSince1970: 1_800_000_000),
            end: Date(timeIntervalSince1970: 1_800_000_002), text: text, source: "mic")
}

@Suite struct Interrupting {
    /// As heard on 2026-10-31, in the middle of the app's own speech.
    @Test func aNameAndTheWordAnywhereInterruptThatApp() {
        let d = InterruptDetector(names: names)
        let out = d.detect(heard("1", .provisional, "A, B, C, D, A. Aristotle Hush"))
        #expect(out.count == 1)
        #expect(out[0].kind == .hush && out[0].to == "peabody" && out[0].heard == "aristotle")
        #expect(out[0].seg == "1" && out[0].text == "hush")
    }

    @Test func eachOccurrenceIsReportedOnceAsTheTextGrows() {
        let d = InterruptDetector(names: names)
        #expect(d.detect(heard("1", .provisional, "Aristotle Hush")).count == 1)
        #expect(d.detect(heard("1", .provisional, "Aristotle Hush. Eight.")).isEmpty)
        #expect(d.detect(heard("1", .provisional, "Aristotle Hush. Eight. Aristotle Hush")).count == 1)
        #expect(d.detect(heard("1", .final, "Aristotle Hush. Eight. Aristotle Hush.")).isEmpty)
        // A later segment starts afresh.
        #expect(d.detect(heard("2", .provisional, "Aristotle, hush")).count == 1)
    }

    @Test func nearSpellingsAndHushedCountButNotOtherWords() {
        let d = InterruptDetector(names: names)
        #expect(d.detect(heard("1", .provisional, "Aristotel hush")).count == 1, "a near spelling of the name")
        #expect(d.detect(heard("2", .provisional, "Aristotle hushed")).count == 1)
        #expect(d.detect(heard("3", .provisional, "Aristotle Hutch")).isEmpty, "short words must match exactly")
        #expect(d.detect(heard("4", .provisional, "Aristotle, tell me about hush money")).isEmpty)
        #expect(d.detect(heard("5", .provisional, "Everybody hush")).isEmpty)
        #expect(d.detect(heard("6", .provisional, "Fred, hush")).first?.to == "scrinotia")
    }

    @Test func theWordIsASetting() {
        let d = InterruptDetector(names: names, word: "quiet")
        #expect(d.detect(heard("1", .provisional, "Aristotle hush")).isEmpty)
        #expect(d.detect(heard("2", .provisional, "Aristotle quiet")).count == 1)
    }

    @Test func anUtteranceThatBeginsWithTheNameAndTheWordIsNotAddressed() {
        let a = Addresser(names: names)
        let hushed = a.address("Aristotle Hush. Oliver was...")
        #expect(hushed.to == nil && hushed.text == "Aristotle Hush. Oliver was...")
        #expect(a.address("Aristotle, tell me about trees.").to == "peabody")
        a.interruptWord = "quiet"
        #expect(a.address("Aristotle, hush.").to == "peabody", "only the word set interrupts")
        #expect(a.address("Aristotle, quiet.").to == nil)
    }

    @Test func theAppsStreamAdmitsItsHushesAndTheyAreFramedAsHush() {
        let mine = StreamFilter(finalOnly: true, to: "peabody")
        let hush = InterruptDetector(names: names).detect(heard("1", .provisional, "Aristotle hush"))[0]
        #expect(mine.admits(hush), "a provisional hush reaches its app")
        #expect(!StreamFilter(finalOnly: true, to: "scrinotia").admits(hush))
        #expect(!mine.admits(heard("1", .provisional, "Aristotle hush")), "ordinary provisional text does not")
        let framed = SSE.frame(Event(id: 9, segment: hush))
        #expect(framed.hasPrefix("id: 9\nevent: hush\n"))
        #expect(framed.contains("\"kind\":\"hush\""))
        #expect(Event(json: Event(id: 9, segment: hush).json)?.segment.kind == .hush)
    }

    @Test func aHushIsNotStored() throws {
        let store = TranscriptStore(directory: tempDir())
        let hub = EventHub(store: store)
        var hush = InterruptDetector(names: names).detect(heard("1", .final, "Aristotle hush"))[0]
        hush.state = .final
        hub.publish(hush)
        hub.publish(heard("2", .final, "something said"))
        #expect(store.events(since: nil, until: nil, to: nil).map(\.segment.text) == ["something said"])
    }
}
