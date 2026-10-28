// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Numbers segments into events, keeps the most recent ones for clients that
/// reconnect, and hands each new event to every subscriber.
public final class EventHub: @unchecked Sendable {
    public typealias Sink = @Sendable (Event) -> Void

    private let lock = NSLock()
    private var nextID: Int
    private var recent: [Event] = []
    private let capacity: Int
    private var sinks: [UUID: (StreamFilter, Sink)] = [:]
    private let store: TranscriptStore?

    /// - Parameters:
    ///   - capacity: how many recent events are kept in memory for reconnecting clients.
    ///   - store: the stored transcript, used to continue numbering after a restart and to
    ///     replay final segments older than the recent buffer.
    public init(capacity: Int = 2000, store: TranscriptStore? = nil) {
        self.capacity = capacity
        self.store = store
        self.nextID = (store?.lastEventID() ?? 0) + 1
    }

    /// Publishes a segment: numbers it, keeps it, stores it if final, and delivers it.
    @discardableResult
    public func publish(_ segment: Segment) -> Event {
        lock.lock()
        let event = Event(id: nextID, segment: segment)
        nextID += 1
        recent.append(event)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
        let targets = sinks.values.filter { $0.0.admits(segment) }.map(\.1)
        lock.unlock()
        if segment.state == .final { store?.append(event) }
        for sink in targets { sink(event) }
        return event
    }

    /// Subscribes, first replaying what came after `lastID` (if given), atomically with
    /// the subscription so that nothing is missed or repeated. Returns a token for `unsubscribe`.
    public func subscribe(filter: StreamFilter, after lastID: Int?, sink: @escaping Sink) -> UUID {
        let token = UUID()
        lock.lock()
        var replay: [Event] = []
        if let lastID {
            let oldestKept = recent.first?.id ?? nextID
            if lastID + 1 < oldestKept, let store {
                // Older than the buffer: only final segments were kept on disk.
                replay += store.events(after: lastID, before: oldestKept)
            }
            replay += recent.filter { $0.id > lastID }
        }
        replay = replay.filter { filter.admits($0.segment) }
        sinks[token] = (filter, sink)
        lock.unlock()
        for e in replay { sink(e) }
        return token
    }

    public func unsubscribe(_ token: UUID) {
        lock.lock()
        sinks[token] = nil
        lock.unlock()
    }

    public var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sinks.count
    }

    /// The most recent events, newest last.
    public func latest(_ n: Int) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return Array(recent.suffix(n))
    }
}
