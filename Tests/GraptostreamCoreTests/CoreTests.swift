// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import GraptostreamCore

func seg(_ id: String, _ state: Segment.State, _ text: String, to: String? = nil, at: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> Segment {
    Segment(seg: id, state: state, start: at, end: at.addingTimeInterval(2), text: text, to: to)
}

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("gs-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite struct SSEFraming {
    @Test func oneEventIsIdTypeDataAndABlankLine() {
        #expect(SSE.frame(id: 7, event: "segment", data: "{\"a\":1}") == "id: 7\nevent: segment\ndata: {\"a\":1}\n\n")
    }

    @Test func multilineDataBecomesSeveralDataLines() {
        #expect(SSE.frame(id: 1, event: "x", data: "a\nb") == "id: 1\nevent: x\ndata: a\ndata: b\n\n")
    }

    @Test func anEventsJSONHasNoNewlineAndRoundTrips() {
        let e = Event(id: 3, segment: seg("0003", .final, "open today's note", to: "scrinotia"))
        #expect(!e.json.contains("\n"))
        #expect(Event(json: e.json) == e)
    }
}

@Suite struct Filters {
    @Test func finalOnlyDropsProvisional() {
        let f = StreamFilter(finalOnly: true)
        #expect(!f.admits(seg("1", .provisional, "a")))
        #expect(f.admits(seg("1", .final, "a")))
    }

    @Test func toAdmitsOnlyFinalsAddressedToThatApp() {
        let f = StreamFilter(to: "Scrinotia")
        #expect(f.admits(seg("1", .final, "x", to: "scrinotia")))
        #expect(!f.admits(seg("1", .final, "x", to: "trixie")))
        #expect(!f.admits(seg("1", .final, "x")))
        #expect(!f.admits(seg("1", .provisional, "x", to: "scrinotia")))
    }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Event] = []
    func add(_ e: Event) { lock.lock(); items.append(e); lock.unlock() }
    var ids: [Int] { lock.lock(); defer { lock.unlock() }; return items.map(\.id) }
}

@Suite struct Hub {
    @Test func eventsAreNumberedInOrder() {
        let hub = EventHub()
        #expect(hub.publish(seg("1", .provisional, "a")).id == 1)
        #expect(hub.publish(seg("1", .final, "a")).id == 2)
    }

    @Test func aSubscriberReceivesNewEvents() {
        let hub = EventHub()
        let got = Collected()
        _ = hub.subscribe(filter: .init(), after: nil) { got.add($0) }
        hub.publish(seg("1", .final, "a"))
        #expect(got.ids == [1])
    }

    @Test func reconnectingWithLastEventIDReplaysWhatWasMissed() {
        let hub = EventHub()
        for i in 1...5 { hub.publish(seg("\(i)", .final, "t\(i)")) }
        let got = Collected()
        let (_, replay) = hub.subscribe(filter: .init(), after: 3) { got.add($0) }
        hub.publish(seg("6", .final, "t6"))
        #expect(replay.map(\.id) == [4, 5])
        #expect(got.ids == [6])
    }

    @Test func eventsOlderThanTheBufferComeFromTheStore() {
        let store = TranscriptStore(directory: tempDir())
        let hub = EventHub(capacity: 2, store: store)
        for i in 1...5 { hub.publish(seg("\(i)", .final, "t\(i)")) }
        let (_, replay) = hub.subscribe(filter: .init(), after: 1) { _ in }
        #expect(replay.map(\.id) == [2, 3, 4, 5])
    }

    @Test func idsAreNeverReusedAfterARestart() {
        let dir = tempDir()
        let first = EventHub(store: TranscriptStore(directory: dir))
        first.publish(seg("1", .final, "a"))
        let lastProvisional = first.publish(seg("2", .provisional, "b"))
        let second = EventHub(store: TranscriptStore(directory: dir))
        #expect(second.publish(seg("3", .final, "c")).id > lastProvisional.id)
    }

    @Test func anOverflowingLastEventIDIsHarmless() {
        let hub = EventHub()
        hub.publish(seg("1", .final, "a"))
        let (_, replay) = hub.subscribe(filter: .init(), after: Int.max) { _ in }
        #expect(replay.isEmpty)
        let (_, all) = hub.subscribe(filter: .init(), after: Int.min) { _ in }
        #expect(all.map(\.id) == [1])
    }

    @Test func emptyFinalsAreNotStored() {
        let store = TranscriptStore(directory: tempDir())
        let hub = EventHub(store: store)
        hub.publish(seg("1", .final, ""))
        #expect(store.events().isEmpty)
    }

    @Test func unsubscribedSinksReceiveNothing() {
        let hub = EventHub()
        let got = Collected()
        let (t, _) = hub.subscribe(filter: .init(), after: nil) { got.add($0) }
        hub.unsubscribe(t)
        hub.publish(seg("1", .final, "a"))
        #expect(got.ids.isEmpty)
    }
}

@Suite struct Requests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aRequestLapsesUnlessRenewed() {
        let r = ListenRequests()
        let req = r.create(client: "notes", minutes: 1, now: t0)
        #expect(r.active(now: t0.addingTimeInterval(59)).count == 1)
        #expect(r.active(now: t0.addingTimeInterval(61)).isEmpty)
        #expect(r.renew(id: req.id, minutes: 1, now: t0.addingTimeInterval(61)) == nil)
    }

    @Test func renewingExtendsTheExpiry() {
        let r = ListenRequests()
        let req = r.create(client: "notes", minutes: 1, now: t0)
        _ = r.renew(id: req.id, minutes: 1, now: t0.addingTimeInterval(50))
        #expect(r.active(now: t0.addingTimeInterval(100)).count == 1)
    }

    @Test func withdrawingOneLeavesTheOthers() {
        let r = ListenRequests()
        let a = r.create(client: "a", minutes: 5, now: t0)
        _ = r.create(client: "b", minutes: 5, now: t0)
        #expect(r.withdraw(id: a.id))
        #expect(r.active(now: t0).map(\.client) == ["b"])
    }
}

@Suite struct Addressing {
    let names = [SpokenName(name: "Fred", app: "scrinotia"), SpokenName(name: "Hazel tracking", app: "hazel-tracking"),
                 SpokenName(name: "Barney", app: "paper-boxing")]

    @Test func aNameAtTheStartAddressesTheApp() {
        let a = Addresser(names: names).address("Fred, open today's note.")
        #expect(a == Addressed(to: "scrinotia", heard: "Fred", text: "open today's note."))
    }

    @Test func aNameInPassingAddressesNothing() {
        let a = Addresser(names: names).address("I told Fred yesterday.")
        #expect(a.to == nil)
        #expect(a.text == "I told Fred yesterday.")
    }

    @Test func nearSpellingsAndPossessivesCount() {
        let ad = Addresser(names: names)
        #expect(ad.address("Barny, list the sites").to == "paper-boxing")
        #expect(ad.address("Fred's going to open the note").to == "scrinotia")
        #expect(ad.address("Ted, open the note").to == nil)  // short names must match exactly
    }

    @Test func shortNamesDoNotMatchCommonWords() {
        let ad = Addresser(names: names)
        for sentence in ["Free time is scarce.", "Feed the cat.", "Fed up with it.", "Red is my colour."] {
            #expect(ad.address(sentence).to == nil)
        }
    }

    @Test func multiwordNamesMatchAndAreRemoved() {
        let a = Addresser(names: names).address("Hazel Tracking, show the open pull requests.")
        #expect(a.to == "hazel-tracking")
        #expect(a.heard == "Hazel Tracking")
        #expect(a.text == "show the open pull requests.")
    }

    @Test func aNameOnItsOwnAddressesTheNextUtterance() {
        let ad = Addresser(names: names)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ad.address("Fred.", start: t, end: t.addingTimeInterval(0.5)).to == "scrinotia")
        // A long command after the name: the gap is measured from the name's end to the command's start.
        let next = ad.address("Open today's note and then read me the first paragraph of it slowly.",
                              start: t.addingTimeInterval(1.5), end: t.addingTimeInterval(8))
        #expect(next.to == "scrinotia")
        #expect(next.heard == "Fred")
        #expect(ad.address("And another thing.", start: t.addingTimeInterval(9), end: t.addingTimeInterval(10)).to == nil)
    }

    @Test func theCarryLapses() {
        let ad = Addresser(names: names, carryWindow: 4)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        _ = ad.address("Fred.", start: t, end: t.addingTimeInterval(0.5))
        #expect(ad.address("Open the note.", start: t.addingTimeInterval(10), end: t.addingTimeInterval(11)).to == nil)
    }
}

@Suite struct Store {
    @Test func finalsAreWrittenAndReadBack() {
        let s = TranscriptStore(directory: tempDir())
        let e = Event(id: 1, segment: seg("1", .final, "hello", to: "fred"))
        s.append(e)
        #expect(s.events() == [e])
        #expect(s.events(to: "FRED") == [e])
        #expect(s.events(to: "wilma").isEmpty)
        #expect(s.lastEventID() == 1)
    }

    @Test func sweepDeletesFilesOlderThanTheRetention() throws {
        let dir = tempDir()
        let s = TranscriptStore(directory: dir)
        for name in ["2026-01-01.jsonl", "2026-03-01.jsonl", "2026-03-30.jsonl"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let now = ISO8601.date(from: "2026-03-31T12:00:00Z")!
        let deleted = s.sweep(retentionDays: 30, now: now)
        #expect(deleted == ["2026-01-01.jsonl"])
        #expect(s.files().map(\.lastPathComponent) == ["2026-03-01.jsonl", "2026-03-30.jsonl"])
    }
}

@Suite struct Parsing {
    @Test func aCompleteRequestParses() {
        let raw = "POST /listen?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}"
        guard case .complete(let r, let used) = HTTPRequest.parse(Data(raw.utf8)) else { Issue.record("not parsed"); return }
        #expect(r.method == "POST")
        #expect(r.path == "/listen")
        #expect(r.query["x"] == "1")
        #expect(r.header("HOST") == "localhost")
        #expect(r.body == Data("{}".utf8))
        #expect(used == raw.utf8.count)
    }

    @Test func aPartialRequestWaitsForMore() {
        #expect(HTTPRequest.parse(Data("GET /events HTTP/1.1\r\nHost: x".utf8)) == .incomplete)
        let raw = "POST /listen HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"
        #expect(HTTPRequest.parse(Data(raw.utf8)) == .incomplete)
    }

    @Test func garbageIsRejected() {
        guard case .invalid = HTTPRequest.parse(Data("hello\r\n\r\n".utf8)) else { Issue.record("accepted"); return }
    }
}

@Suite struct AccessRules {
    let policy: AccessPolicy
    let secret: String

    init() {
        let (t, s) = ClientToken.make(name: "vision-pro")
        policy = AccessPolicy(port: 35860, tokens: [t])
        secret = s
    }

    func req(_ headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: "GET", path: "/events", query: [:],
                    headers: Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }), body: Data())
    }

    @Test func theSocketNeedsNothing() {
        #expect(policy.decide(req([:]), from: .socket) == .allow(client: nil))
    }

    @Test func loopbackNeedsALocalHost() {
        #expect(policy.decide(req(["Host": "localhost:35860"]), from: .loopback) == .allow(client: nil))
        #expect(policy.decide(req(["Host": "evil.example:35860"]), from: .loopback) != .allow(client: nil))
        #expect(policy.decide(req([:]), from: .loopback) != .allow(client: nil))
    }

    @Test func loopbackRefusesACrossSitePageWithoutAnOrigin() {
        // An <img> or a simple GET from another site carries no Origin, but does carry Sec-Fetch-Site.
        let r = req(["Host": "127.0.0.1:35860", "Sec-Fetch-Site": "cross-site"])
        #expect(policy.decide(r, from: .loopback) == .deny(status: 403, reason: "cross-site requests are not accepted"))
        let typed = req(["Host": "127.0.0.1:35860", "Sec-Fetch-Site": "none"])
        #expect(policy.decide(typed, from: .loopback) == .allow(client: nil))
    }

    @Test func loopbackRefusesAForeignOrigin() {
        let r = req(["Host": "127.0.0.1:35860", "Origin": "https://evil.example"])
        #expect(policy.decide(r, from: .loopback) != .allow(client: nil))
        let ok = req(["Host": "127.0.0.1:35860", "Origin": "http://127.0.0.1:35860"])
        #expect(policy.decide(ok, from: .loopback) == .allow(client: nil))
    }

    @Test func theNetworkNeedsAKnownToken() {
        guard case .allow(let client, let token) = policy.decide(req(["Authorization": "Bearer \(secret)"]), from: .network) else {
            Issue.record("refused"); return
        }
        #expect(client == "vision-pro")
        #expect(token == policy.tokens[0].id)
        #expect(policy.decide(req(["Authorization": "Bearer gs_wrong"]), from: .network) == .deny(status: 401, reason: "unknown token"))
        #expect(policy.decide(req([:]), from: .network) == .deny(status: 401, reason: "a bearer token is required"))
    }
}

@Suite struct Timing {
    // Values from a recording with 40 s of silence before "Knock, knock"
    // (2026-10-29): the first provisional with words covered 0 to 41.4 s.
    @Test func aProvisionalSegmentStartsWhenItsWordsWereFirstHeard() {
        var t = SegmentTiming()
        #expect(t.provisional(rangeEnd: 41.4, hasWords: true) == 41.4)
        #expect(t.provisional(rangeEnd: 42.4, hasWords: true) == 41.4)
    }

    @Test func punctuationAloneDoesNotStartTheSegment() {
        var t = SegmentTiming()
        _ = t.provisional(rangeEnd: 20.3, hasWords: false)
        #expect(t.firstHeard == nil)
        #expect(t.provisional(rangeEnd: 41.4, hasWords: true) == 41.4)
    }

    @Test func silenceBeforeTheSpeechDoesNotCountTowardsTheLimit() {
        var t = SegmentTiming()
        _ = t.provisional(rangeEnd: 41.4, hasWords: true)
        #expect(!t.isTooLong(end: 44.3, limit: 30))
        #expect(t.isTooLong(end: 71.5, limit: 30))
    }

    @Test func nothingIsTooLongBeforeAWordIsHeard() {
        var t = SegmentTiming()
        _ = t.provisional(rangeEnd: 60, hasWords: false)
        #expect(!t.isTooLong(end: 60, limit: 30))
    }

    @Test func resetBeginsANewSegment() {
        var t = SegmentTiming()
        _ = t.provisional(rangeEnd: 41.4, hasWords: true)
        t.reset()
        #expect(t.firstHeard == nil)
        #expect(t.provisional(rangeEnd: 42.4, hasWords: true) == 42.4)
    }
}
