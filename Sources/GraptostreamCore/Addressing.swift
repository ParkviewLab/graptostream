// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A spoken name and the app it stands for ("Fred" → "scrinotia").
public struct SpokenName: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    public var app: String
    public var id: String { name.lowercased() }

    public init(name: String, app: String) {
        self.name = name
        self.app = app
    }
}

/// The outcome of addressing one final utterance.
public struct Addressed: Sendable, Equatable {
    /// The app addressed, and the name as heard; nil when the utterance is not addressed.
    public var to: String?
    public var heard: String?
    /// The text for the addressed app: the words after the name. The whole text when unaddressed.
    public var text: String
}

/// Decides which app a final utterance is addressed to. A spoken name counts only
/// at the start of an utterance, matched loosely (a near spelling or a possessive
/// counts for names of six letters or more; shorter names must match exactly, so
/// that "Fred" is not heard in "free", "feed" or "red"). A final that is nothing but
/// a name addresses the next final, if it starts within `carryWindow` of the name's
/// end, since a pause after the name can make the speech engine end the utterance there.
public final class Addresser: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [SpokenName]
    private var pending: (name: SpokenName, heard: String, end: Date)?
    public var carryWindow: TimeInterval
    /// The word that, after a spoken name, interrupts that app rather than addressing it
    /// (see `InterruptDetector`); an utterance that begins with the name and this word is
    /// not addressed.
    public var interruptWord: String {
        get { lock.withLock { _interruptWord } }
        set { lock.withLock { _interruptWord = newValue } }
    }
    private var _interruptWord = "hush"

    public init(names: [SpokenName] = [], carryWindow: TimeInterval = 4) {
        self.names = names
        self.carryWindow = carryWindow
    }

    public func setNames(_ names: [SpokenName]) {
        lock.lock()
        self.names = names
        pending = nil
        lock.unlock()
    }

    /// Words of a text, lowercased, with punctuation and possessives removed, each with
    /// the range it came from in the original.
    static func words(_ text: String) -> [(word: String, range: Range<String.Index>)] {
        var out: [(String, Range<String.Index>)] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { sub, range, _, _ in
            guard var w = sub?.lowercased() else { return }
            for suffix in ["'s", "’s"] where w.hasSuffix(suffix) { w.removeLast(2) }
            out.append((w, range))
        }
        return out
    }

    /// Edit distance between two short strings.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    /// How far a heard word may be from a name's word and still count.
    static func tolerance(_ word: String) -> Int {
        switch word.count {
        case ..<6: 0
        case 6...8: 1
        default: 2
        }
    }

    /// Whether a heard word is the interrupt word: exactly, or with "ed" ("hushed"), or a
    /// near spelling for a word of six letters or more.
    static func isInterrupt(_ heard: String, word: String) -> Bool {
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return false }
        return heard == w || heard == w + "ed" || distance(heard, w) <= tolerance(w)
    }

    /// Whether the words from `at` match a name's words, loosely as `match` does.
    static func matches(_ parts: [String], _ ws: [(word: String, range: Range<String.Index>)], at i: Int) -> Bool {
        guard !parts.isEmpty, i + parts.count <= ws.count else { return false }
        return zip(parts, ws[i..<(i + parts.count)]).allSatisfy { p, w in distance(p, w.word) <= tolerance(p) }
    }

    /// The longest spoken name that the utterance's first words match, with the number of words it used.
    func match(_ ws: [(word: String, range: Range<String.Index>)]) -> (SpokenName, Int)? {
        var best: (SpokenName, Int)?
        for n in names {
            let parts = Self.words(n.name).map(\.word)
            guard !parts.isEmpty, ws.count >= parts.count else { continue }
            let fits = zip(parts, ws.prefix(parts.count)).allSatisfy { p, w in
                Self.distance(p, w.word) <= Self.tolerance(p)
            }
            if fits, parts.count > (best?.1 ?? 0) { best = (n, parts.count) }
        }
        return best
    }

    /// Addresses one final utterance spoken from `start` to `end`.
    public func address(_ text: String, start: Date = Date(), end: Date? = nil) -> Addressed {
        let end = end ?? start
        lock.lock()
        defer { lock.unlock() }
        let ws = Self.words(text)
        if let (name, used) = match(ws) {
            let heard = String(text[ws[0].range.lowerBound..<ws[used - 1].range.upperBound])
            let rest = used < ws.count ? String(text[ws[used].range.lowerBound...]) : ""
            let restTrimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if restTrimmed.isEmpty {
                // A name on its own: it addresses what follows.
                pending = (name, heard, end)
                return Addressed(to: name.app, heard: heard, text: "")
            }
            pending = nil
            if used < ws.count, Self.isInterrupt(ws[used].word, word: _interruptWord) {
                // "<name> hush …" interrupts the app (as a hush event) and goes to no one.
                return Addressed(to: nil, heard: nil, text: text)
            }
            return Addressed(to: name.app, heard: heard, text: restTrimmed)
        }
        if let p = pending, start.timeIntervalSince(p.end) <= carryWindow, !ws.isEmpty {
            pending = nil
            return Addressed(to: p.name.app, heard: p.heard, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        pending = nil
        return Addressed(to: nil, heard: nil, text: text)
    }
}

/// Finds interruptions: a spoken name, or a near spelling of it, followed by the
/// interrupt word ("Aristotle, hush"), anywhere in what is heard, also in the middle of
/// another voice's sentence. Each new occurrence in a segment yields one `hush` event,
/// from provisional text, so that it reaches its app within a fraction of a second.
public final class InterruptDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [SpokenName] = []
    private var word = "hush"
    /// Occurrences already reported, by segment and app.
    private var seen: [String: [String: Int]] = [:]

    public init(names: [SpokenName] = [], word: String = "hush") {
        self.names = names
        self.word = word
    }

    public func setNames(_ names: [SpokenName]) { lock.withLock { self.names = names } }

    public func setWord(_ word: String) { lock.withLock { self.word = word } }

    /// The hush events that `s` brings: one for each occurrence not yet reported.
    public func detect(_ s: Segment) -> [Segment] {
        guard s.kind == nil else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let ws = Addresser.words(s.full.isEmpty ? s.text : s.full)
        var counts: [String: (count: Int, heard: String)] = [:]
        for i in ws.indices {
            for n in names {
                let parts = Addresser.words(n.name).map(\.word)
                let after = i + parts.count
                guard after < ws.count, Addresser.matches(parts, ws, at: i),
                      Addresser.isInterrupt(ws[after].word, word: word) else { continue }
                let heard = ws[i..<after].map(\.word).joined(separator: " ")
                counts[n.app.lowercased(), default: (0, heard)].count += 1
            }
        }
        var out: [Segment] = []
        var known = seen[s.seg] ?? [:]
        for (app, c) in counts.sorted(by: { $0.key < $1.key }) where c.count > known[app, default: 0] {
            for _ in 0..<(c.count - known[app, default: 0]) {
                out.append(Segment(seg: s.seg, state: s.state, start: s.start, end: s.end, text: word,
                                   full: "\(c.heard) \(word)", to: app, heard: c.heard, source: s.source,
                                   kind: .hush))
            }
            known[app] = c.count
        }
        if s.state == .final { seen[s.seg] = nil } else { seen[s.seg] = known }
        return out
    }
}
