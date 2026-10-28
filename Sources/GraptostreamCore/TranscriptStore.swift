// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The stored transcript: final segments as JSON Lines, one file per day
/// (`YYYY-MM-DD.jsonl`, by local date), deleted after the retention period.
public final class TranscriptStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private let calendar: Calendar

    public init(directory: URL, calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func fileName(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func append(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        let url = directory.appendingPathComponent(fileName(for: event.segment.end))
        let line = Data((event.json + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// The day files, oldest first.
    public func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.sorted().map { directory.appendingPathComponent($0) }
    }

    private func read(_ url: URL) -> [Event] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { Event(json: String($0)) }
    }

    /// Events between two times (inclusive start, exclusive end), optionally addressed to one app.
    public func events(since: Date? = nil, until: Date? = nil, to: String? = nil) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return files().flatMap(read).filter { e in
            (since.map { e.segment.end >= $0 } ?? true)
                && (until.map { e.segment.start < $0 } ?? true)
                && (to.map { e.segment.to?.caseInsensitiveCompare($0) == .orderedSame } ?? true)
        }
    }

    /// Stored events with ids in `(after, before)`.
    public func events(after: Int, before: Int) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return files().flatMap(read).filter { $0.id > after && $0.id < before }
    }

    /// The highest event id stored, to continue numbering after a restart.
    public func lastEventID() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        for url in files().reversed() {
            if let last = read(url).last { return last.id }
        }
        return nil
    }

    /// Deletes the day files older than `days` days before `now`. Returns the files deleted.
    @discardableResult
    public func sweep(retentionDays days: Int, now: Date = Date()) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard days > 0, let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) else { return [] }
        let cutoffName = fileName(for: cutoff)
        var deleted: [String] = []
        for url in files() where url.lastPathComponent < cutoffName {
            if (try? FileManager.default.removeItem(at: url)) != nil { deleted.append(url.lastPathComponent) }
        }
        return deleted
    }
}
