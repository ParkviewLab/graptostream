// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import GraptostreamCore

final class FakeBackend: ServiceBackend, @unchecked Sendable {
    let requests = ListenRequests()
    let store = TranscriptStore(directory: tempDir())
    var changes = 0
    func status() -> ServiceStatus {
        ServiceStatus(version: "0.0.0", listening: !requests.active().isEmpty, reason: "test", mode: "auto",
                      microphones: [], readers: [], requests: requests.active())
    }
    func requestsChanged() { changes += 1 }
}

/// Runs curl against the server and returns its output.
func curl(_ args: [String], timeout: TimeInterval = 5) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "--max-time", "\(timeout)"] + args
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

@Suite(.serialized) struct ServerEndToEnd {
    let hub = EventHub()
    let backend = FakeBackend()
    let server: Server
    let socket: String
    let port: UInt16 = UInt16.random(in: 40000...49000)

    init() async throws {
        socket = FileManager.default.temporaryDirectory.appendingPathComponent("gs-\(UUID().uuidString.prefix(8)).sock").path
        server = Server(hub: hub, router: Router(backend: backend, version: "0.0.0"), tokens: [])
        server.start(.init(socketPath: socket, port: port, lan: false))
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    @Test func healthAnswersOnTheSocketAndLoopback() throws {
        #expect(try curl(["--unix-socket", socket, "http://localhost/health"]).contains("\"ok\":true"))
        #expect(try curl(["http://127.0.0.1:\(port)/health"]).contains("\"ok\":true"))
        server.stop()
    }

    @Test func theSocketIsForThisUserOnly() throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: socket)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        server.stop()
    }

    @Test func aForeignHostIsRefusedOnLoopback() throws {
        let out = try curl(["-H", "Host: evil.example", "http://127.0.0.1:\(port)/health"])
        #expect(out.contains("Host must be"))
        server.stop()
    }

    @Test func listenRequestsAreCreatedAndWithdrawn() throws {
        let created = try curl(["--unix-socket", socket, "-X", "POST", "-d", "{\"client\":\"notes\",\"minutes\":2}",
                                "http://localhost/listen"])
        let id = try #require((try? JSONSerialization.jsonObject(with: Data(created.utf8))) as? [String: Any])["id"] as? String
        #expect(backend.requests.active().count == 1)
        _ = try curl(["--unix-socket", socket, "-X", "DELETE", "http://localhost/listen/\(id ?? "")"])
        #expect(backend.requests.active().isEmpty)
        server.stop()
    }

    @Test func theStreamDeliversPublishedSegments() async throws {
        let hub = self.hub
        let publisher = Task {
            try await Task.sleep(nanoseconds: 600_000_000)
            hub.publish(seg("0001", .provisional, "open"))
            hub.publish(seg("0001", .final, "open today's note"))
        }
        let out = try curl(["-N", "--unix-socket", socket, "http://localhost/events"], timeout: 2)
        try await publisher.value
        #expect(out.contains("event: segment"))
        #expect(out.contains("\"state\":\"provisional\""))
        #expect(out.contains("\"text\":\"open today's note\""))
        server.stop()
    }

    @Test func aReconnectingClientCatchesUp() throws {
        for i in 1...3 { hub.publish(seg("\(i)", .final, "t\(i)")) }
        let out = try curl(["-N", "-H", "Last-Event-ID: 1", "--unix-socket", socket, "http://localhost/events"], timeout: 1)
        #expect(!out.contains("id: 1\n"))
        #expect(out.contains("id: 2\n"))
        #expect(out.contains("id: 3\n"))
        server.stop()
    }
}
