// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A piece of transcribed speech. Provisional versions are replaced by the final
/// version that carries the same `seg` id.
public struct Segment: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case provisional, final }

    /// The segment's id, shared by its provisional versions and its final version.
    public var seg: String
    public var state: State
    /// Wall-clock start and end of the speech.
    public var start: Date
    public var end: Date
    /// The text for its reader: for an addressed final, the words after the spoken name.
    public var text: String
    /// Everything that was heard, the spoken name included.
    public var full: String
    /// The app the utterance is addressed to, and the name as it was heard.
    public var to: String?
    public var heard: String?
    /// The input that carried the speech (a microphone, or one of its channels).
    public var source: String?

    public init(seg: String, state: State, start: Date, end: Date, text: String, full: String? = nil,
                to: String? = nil, heard: String? = nil, source: String? = nil) {
        self.seg = seg
        self.state = state
        self.start = start
        self.end = end
        self.text = text
        self.full = full ?? text
        self.to = to
        self.heard = heard
        self.source = source
    }
}

/// A segment as published on the stream, numbered in order of publication.
public struct Event: Codable, Sendable, Equatable {
    public var id: Int
    public var segment: Segment

    public init(id: Int, segment: Segment) {
        self.id = id
        self.segment = segment
    }
}

/// The JSON coders used everywhere: compact, sorted keys, ISO 8601 dates with milliseconds.
public enum JSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.string(from: date))
        }
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISO8601.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(s)")
            }
            return date
        }
        return d
    }()

    public static func string<T: Encodable>(_ value: T) -> String {
        (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
    }
}

public enum ISO8601 {
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    public static func string(from date: Date) -> String { formatter(fractional: true).string(from: date) }

    public static func date(from string: String) -> Date? {
        formatter(fractional: true).date(from: string) ?? formatter(fractional: false).date(from: string)
    }
}

/// The JSON form of an event as written to the stream and to the stored transcript:
/// the segment's fields with the event id beside them.
struct EventRecord: Codable {
    var id: Int
    var seg: String
    var state: Segment.State
    var start: Date
    var end: Date
    var text: String
    var full: String
    var to: String?
    var heard: String?
    var source: String?

    init(_ e: Event) {
        id = e.id
        seg = e.segment.seg
        state = e.segment.state
        start = e.segment.start
        end = e.segment.end
        text = e.segment.text
        full = e.segment.full
        to = e.segment.to
        heard = e.segment.heard
        source = e.segment.source
    }

    var event: Event {
        Event(id: id, segment: Segment(seg: seg, state: state, start: start, end: end, text: text, full: full,
                                       to: to, heard: heard, source: source))
    }
}

extension Event {
    /// The event as one line of JSON (no newline inside).
    public var json: String { JSON.string(EventRecord(self)) }

    public init?(json: String) {
        guard let r = try? JSON.decoder.decode(EventRecord.self, from: Data(json.utf8)) else { return nil }
        self = r.event
    }
}
