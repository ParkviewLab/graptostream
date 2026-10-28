// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Numbers segments into events, keeps the most recent ones for clients that
/// reconnect, and hands each new event to every subscriber.
public final class EventHub: @unchecked Sendable {
    public typealias Sink = @Sendable (Event) -> Void

    /// Ids are reserved in blocks and the block's end is stored, so that ids are never
    /// reused after a restart, provisional ones included (only finals are stored).
    static let reservation = 1000

    private let lock = NSLock()
    private var nextID: Int
    private var reservedThrough: Int
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
        let start = max(store?.lastEventID() ?? 0, store?.reservedEventID() ?? 0) + 1
        nextID = start
        reservedThrough = start + Self.reservation
        store?.reserveEventIDs(through: reservedThrough)
    }

    /// Publishes a segment: numbers it, keeps it, stores it if it is a final with text,
    /// and delivers it.
    @discardableResult
    public func publish(_ segment: Segment) -> Event {
        lock.lock()
        let event = Event(id: nextID, segment: segment)
        nextID += 1
        var reserve: Int?
        if nextID >= reservedThrough {
            reservedThrough = nextID + Self.reservation
            reserve = reservedThrough
        }
        recent.append(event)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
        let targets = sinks.values.filter { $0.0.admits(segment) }.map(\.1)
        lock.unlock()
        if let reserve { store?.reserveEventIDs(through: reserve) }
        if segment.state == .final, !segment.full.isEmpty { store?.append(event) }
        for sink in targets { sink(event) }
        return event
    }

    /// Subscribes `sink` to new events and returns, beside the token for `unsubscribe`,
    /// the events after `lastID` that the subscriber missed, oldest first. Every event is
    /// either in that replay or delivered to the sink, never both; the sink may be called
    /// before the caller has sent the replay, so the caller orders them (see Server).
    public func subscribe(filter: StreamFilter, after lastID: Int?, sink: @escaping Sink) -> (token: UUID, replay: [Event]) {
        let token = UUID()
        var older: [Event] = []
        if let lastID {
            lock.lock()
            let oldestKept = recent.first?.id ?? nextID
            lock.unlock()
            // Older than the buffer: only final segments were kept on disk. Read outside the lock.
            if lastID < oldestKept - 1, let store {
                older = store.events(after: lastID, before: oldestKept)
            }
        }
        lock.lock()
        var replay = older
        if let lastID {
            let after = max(lastID, older.last?.id ?? lastID)
            replay += recent.filter { $0.id > after }
        }
        sinks[token] = (filter, sink)
        lock.unlock()
        return (token, replay.filter { filter.admits($0.segment) })
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
