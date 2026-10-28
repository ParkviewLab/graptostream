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
/// counts). A final that is nothing but a name addresses the next final, if it
/// follows within `carryWindow`, since a pause after the name can make the speech
/// engine end the utterance there.
public final class Addresser: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [SpokenName]
    private var pending: (name: SpokenName, heard: String, at: Date)?
    public var carryWindow: TimeInterval

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
        case ..<4: 0
        case 4...7: 1
        default: 2
        }
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

    /// Addresses one final utterance heard at `at`.
    public func address(_ text: String, at: Date = Date()) -> Addressed {
        lock.lock()
        defer { lock.unlock() }
        let ws = Self.words(text)
        if let (name, used) = match(ws) {
            let heard = String(text[ws[0].range.lowerBound..<ws[used - 1].range.upperBound])
            let rest = used < ws.count ? String(text[ws[used].range.lowerBound...]) : ""
            let restTrimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if restTrimmed.isEmpty {
                // A name on its own: it addresses what follows.
                pending = (name, heard, at)
                return Addressed(to: name.app, heard: heard, text: "")
            }
            pending = nil
            return Addressed(to: name.app, heard: heard, text: restTrimmed)
        }
        if let p = pending, at.timeIntervalSince(p.at) <= carryWindow, !ws.isEmpty {
            pending = nil
            return Addressed(to: p.name.app, heard: p.heard, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        pending = nil
        return Addressed(to: nil, heard: nil, text: text)
    }
}
