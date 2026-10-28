// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Server-Sent Events framing.
public enum SSE {
    /// One event: its id, its type and its data, each data line prefixed, ending with a blank line.
    public static func frame(id: Int, event: String, data: String) -> String {
        var out = "id: \(id)\nevent: \(event)\n"
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            out += "data: \(line.replacingOccurrences(of: "\r", with: ""))\n"
        }
        return out + "\n"
    }

    public static func frame(_ e: Event) -> String { frame(id: e.id, event: "segment", data: e.json) }

    /// A comment line, which keeps a connection alive and is ignored by clients.
    public static let keepAlive = ": keep-alive\n\n"

    /// The headers that open a stream.
    public static let responseHead =
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n"
}

/// What a subscriber wants from the stream.
public struct StreamFilter: Sendable, Equatable {
    /// Only final segments.
    public var finalOnly: Bool
    /// Only segments addressed to this app (implies final segments, since only finals are addressed).
    public var to: String?

    public init(finalOnly: Bool = false, to: String? = nil) {
        self.finalOnly = finalOnly
        self.to = to
    }

    public func admits(_ s: Segment) -> Bool {
        if let to {
            return s.state == .final && s.to?.caseInsensitiveCompare(to) == .orderedSame
        }
        return !finalOnly || s.state == .final
    }
}
