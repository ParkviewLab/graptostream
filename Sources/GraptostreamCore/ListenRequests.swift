// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A client's request that the app listen, until it expires unless renewed.
public struct ListenRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var client: String
    public var created: Date
    public var expires: Date
}

/// The live listening requests. The app listens while any request is live
/// (or while the owner has set it to listen regardless).
public final class ListenRequests: @unchecked Sendable {
    public static let maximumMinutes = 24 * 60

    private let lock = NSLock()
    private var requests: [String: ListenRequest] = [:]

    public init() {}

    private func clamp(_ minutes: Double) -> Double { min(max(minutes, 0.1), Double(Self.maximumMinutes)) }

    public func create(client: String, minutes: Double, now: Date = Date()) -> ListenRequest {
        let r = ListenRequest(id: UUID().uuidString.lowercased(), client: client, created: now,
                              expires: now.addingTimeInterval(clamp(minutes) * 60))
        lock.lock()
        requests[r.id] = r
        lock.unlock()
        return r
    }

    /// Extends a live request; nil if it is unknown or has lapsed.
    public func renew(id: String, minutes: Double, now: Date = Date()) -> ListenRequest? {
        lock.lock()
        defer { lock.unlock() }
        prune(now)
        guard var r = requests[id] else { return nil }
        r.expires = now.addingTimeInterval(clamp(minutes) * 60)
        requests[id] = r
        return r
    }

    @discardableResult
    public func withdraw(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requests.removeValue(forKey: id) != nil
    }

    /// The live requests, soonest to expire first.
    public func active(now: Date = Date()) -> [ListenRequest] {
        lock.lock()
        defer { lock.unlock() }
        prune(now)
        return requests.values.sorted { $0.expires < $1.expires }
    }

    private func prune(_ now: Date) {
        requests = requests.filter { $0.value.expires > now }
    }
}
