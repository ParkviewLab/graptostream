// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The service's state as `/status` reports it and the window shows it.
public struct ServiceStatus: Codable, Sendable, Equatable {
    public struct Microphone: Codable, Sendable, Equatable {
        public var uid: String
        public var name: String
        public var selected: Bool
        public var bluetooth: Bool
        public init(uid: String, name: String, selected: Bool, bluetooth: Bool) {
            self.uid = uid
            self.name = name
            self.selected = selected
            self.bluetooth = bluetooth
        }
    }

    public struct Client: Codable, Sendable, Equatable {
        public var name: String
        public var via: String
        public var since: Date
        public init(name: String, via: String, since: Date) {
            self.name = name
            self.via = via
            self.since = since
        }
    }

    public var name = "graptostream"
    public var version: String
    public var listening: Bool
    public var reason: String
    /// "auto" (listen while a request is live), "always", or "off".
    public var mode: String
    public var microphones: [Microphone]
    /// Clients reading the stream now.
    public var readers: [Client]
    public var requests: [ListenRequest]

    public init(version: String, listening: Bool, reason: String, mode: String, microphones: [Microphone],
                readers: [Client], requests: [ListenRequest]) {
        self.version = version
        self.listening = listening
        self.reason = reason
        self.mode = mode
        self.microphones = microphones
        self.readers = readers
        self.requests = requests
    }
}

/// What the router needs from the running app.
public protocol ServiceBackend: AnyObject, Sendable {
    func status() -> ServiceStatus
    var requests: ListenRequests { get }
    var store: TranscriptStore { get }
    /// Called after a listening request is created, renewed or withdrawn.
    func requestsChanged()
}

/// What a request turns into: a plain response, or a stream the server keeps open.
public enum Route: Equatable {
    case response(HTTPResponse)
    case stream(filter: StreamFilter, lastID: Int?, client: String)
}

/// Maps requests to responses. Access has been decided before routing.
public struct Router {
    public let backend: ServiceBackend
    public let version: String

    public init(backend: ServiceBackend, version: String) {
        self.backend = backend
        self.version = version
    }

    struct ListenBody: Decodable {
        var client: String?
        var minutes: Double?
    }

    struct Health: Encodable {
        var ok = true
        var name = "graptostream"
        var version: String
    }

    struct TranscriptBody: Encodable {
        var events: [TranscriptEntry]
    }

    /// One stored event, flattened as on the stream.
    struct TranscriptEntry: Encodable {
        var record: EventRecord
        func encode(to encoder: Encoder) throws { try record.encode(to: encoder) }
    }

    static func flag(_ v: String?) -> Bool { ["1", "true", "yes"].contains(v?.lowercased() ?? "") }

    public func route(_ req: HTTPRequest, client: String?) -> Route {
        let parts = req.path.split(separator: "/").map(String.init)
        switch (req.method, parts.first ?? "", parts.count) {
        case ("GET", "health", 1):
            return .response(.json(Health(version: version)))
        case ("GET", "status", 1):
            return .response(.json(backend.status()))
        case ("GET", "events", 1):
            let filter = StreamFilter(finalOnly: Self.flag(req.query["final"]), to: req.query["to"].flatMap { $0.isEmpty ? nil : $0 })
            let lastID = (req.header("last-event-id") ?? req.query["last_id"]).flatMap { Int($0) }
            let name = client ?? req.query["client"] ?? req.header("user-agent") ?? "unnamed"
            return .stream(filter: filter, lastID: lastID, client: name)
        case ("GET", "transcript", 1):
            let since = req.query["since"].flatMap(ISO8601.date)
            let until = req.query["until"].flatMap(ISO8601.date)
            if req.query["since"] != nil, since == nil { return .response(.error(400, "since must be an ISO 8601 time")) }
            if req.query["until"] != nil, until == nil { return .response(.error(400, "until must be an ISO 8601 time")) }
            let events = backend.store.events(since: since, until: until, to: req.query["to"])
            return .response(.json(TranscriptBody(events: events.map { TranscriptEntry(record: EventRecord($0)) })))
        case ("POST", "listen", 1):
            let body = (try? JSONDecoder().decode(ListenBody.self, from: req.body)) ?? ListenBody()
            let who = client ?? body.client ?? "unnamed"
            let r = backend.requests.create(client: who, minutes: body.minutes ?? 5)
            backend.requestsChanged()
            return .response(.json(r, status: 201))
        case ("PUT", "listen", 2):
            let body = (try? JSONDecoder().decode(ListenBody.self, from: req.body)) ?? ListenBody()
            guard let r = backend.requests.renew(id: parts[1], minutes: body.minutes ?? 5) else {
                return .response(.error(404, "no live request with that id"))
            }
            backend.requestsChanged()
            return .response(.json(r))
        case ("DELETE", "listen", 2):
            guard backend.requests.withdraw(id: parts[1]) else { return .response(.error(404, "no live request with that id")) }
            backend.requestsChanged()
            return .response(HTTPResponse(status: 204, body: Data()))
        case (_, "health", 1), (_, "status", 1), (_, "events", 1), (_, "transcript", 1), (_, "listen", _):
            return .response(.error(405, "method not allowed"))
        default:
            return .response(.error(404, "not found"))
        }
    }
}
