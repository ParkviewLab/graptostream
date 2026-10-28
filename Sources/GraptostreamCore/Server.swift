// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Network

/// The HTTP server: a Unix socket for this Mac's user, a TCP port on loopback,
/// and, when switched on, the same TCP port on every interface for the LAN,
/// advertised by Bonjour. Plain HTTP/1.1, one request per connection, except
/// `/events`, which stays open as a Server-Sent Events stream.
public final class Server: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var socketPath: String
        public var port: UInt16
        public var lan: Bool
        public var bonjourName: String?
        public init(socketPath: String, port: UInt16, lan: Bool, bonjourName: String? = nil) {
            self.socketPath = socketPath
            self.port = port
            self.lan = lan
            self.bonjourName = bonjourName
        }
    }

    /// A client reading the stream.
    public struct Reader: Sendable {
        public var name: String
        public var via: String
        public var since: Date
        /// The id of the token a LAN client showed.
        public var token: String?
    }

    public static let bonjourType = "_graptostream._tcp"
    /// A client that has this many unsent writes is dropped; it catches up on reconnecting.
    public static let maximumPendingSends = 500
    public static let keepAliveInterval: TimeInterval = 15
    /// A connection that has not sent a whole request in this time is closed.
    public static let requestTimeout: TimeInterval = 10
    /// Connections beyond this many are refused at once.
    public static let maximumConnections = 256

    private let queue = DispatchQueue(label: "graptostream.server")
    private let hub: EventHub
    private let router: Router
    private let lock = NSLock()
    private var policy: AccessPolicy
    private var listeners: [NWListener] = []
    private var readers: [ObjectIdentifier: Reader] = [:]
    private var streams: [ObjectIdentifier: Stream] = [:]
    private var connections = 0
    private var _configuration: Configuration?
    private var _lastError: String?
    /// Called on the server's queue when readers or listener state change.
    public var onChange: (@Sendable () -> Void)?

    public init(hub: EventHub, router: Router, tokens: [ClientToken]) {
        self.hub = hub
        self.router = router
        self.policy = AccessPolicy(port: 0, tokens: tokens)
    }

    public var configuration: Configuration? { lock.withLock { _configuration } }
    /// The last error a listener reported, for the window to show.
    public var lastError: String? { lock.withLock { _lastError } }

    /// Replaces the tokens, and closes the streams of LAN clients whose token was revoked.
    public func setTokens(_ tokens: [ClientToken]) {
        let ids = Set(tokens.map(\.id))
        let revoked: [Stream] = lock.withLock {
            policy.tokens = tokens
            return readers.compactMap { key, r in
                guard let t = r.token, !ids.contains(t) else { return nil }
                return streams[key]
            }
        }
        for s in revoked { s.drop() }
    }

    public func currentReaders() -> [Reader] {
        lock.withLock { readers.values.sorted { $0.since < $1.since } }
    }

    // MARK: listening

    public func start(_ config: Configuration) {
        stop()
        lock.withLock {
            _configuration = config
            policy.port = config.port
            _lastError = nil
        }

        // The Unix socket, readable and writable by this user only.
        unlink(config.socketPath)
        let unixParams = NWParameters.tcp
        unixParams.requiredLocalEndpoint = .unix(path: config.socketPath)
        add(listener: try? NWListener(using: unixParams), source: { _ in .socket }, label: "socket") {
            chmod(config.socketPath, 0o600)
        }

        // TCP: loopback only, or every interface when the LAN listener is on.
        let tcpParams = NWParameters.tcp
        tcpParams.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            note(error: "port \(config.port) is not valid")
            return
        }
        if !config.lan {
            tcpParams.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        }
        let tcp = config.lan ? try? NWListener(using: tcpParams, on: port) : try? NWListener(using: tcpParams)
        if config.lan, let tcp {
            tcp.service = NWListener.Service(name: config.bonjourName, type: Self.bonjourType)
        }
        add(listener: tcp, source: { conn in Self.isLoopback(conn) ? .loopback : .network }, label: "tcp", onReady: {})
    }

    public func stop() {
        let (ls, ss, path): ([NWListener], [Stream], String?) = lock.withLock {
            let out = (listeners, Array(streams.values), _configuration?.socketPath)
            listeners = []
            return out
        }
        for l in ls { l.cancel() }
        for s in ss { s.drop() }
        if let path { unlink(path) }
    }

    private func add(listener: NWListener?, source: @escaping @Sendable (NWConnection) -> RequestSource,
                     label: String, onReady: @escaping @Sendable () -> Void) {
        guard let listener else {
            note(error: "the \(label) listener could not be created")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: onReady()
            case .failed(let e): self?.note(error: "\(label): \(e.localizedDescription)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn, source: source(conn)) }
        listener.start(queue: queue)
        lock.withLock { listeners.append(listener) }
    }

    private func note(error: String) {
        lock.withLock { _lastError = error }
        onChange?()
    }

    static func isLoopback(_ conn: NWConnection) -> Bool {
        if case .hostPort(let host, _) = conn.endpoint {
            switch host {
            case .ipv4(let a): return a == .loopback || "\(a)".hasPrefix("127.")
            case .ipv6(let a): return a == .loopback || "\(a)".hasPrefix("::ffff:127.")
            case .name(let n, _): return n == "localhost"
            @unknown default: return false
            }
        }
        return false
    }

    // MARK: connections

    private func accept(_ conn: NWConnection, source: RequestSource) {
        let admitted: Bool = lock.withLock {
            guard connections < Self.maximumConnections else { return false }
            connections += 1
            return true
        }
        guard admitted else {
            conn.cancel()
            return
        }
        let released = Flag()
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                if released.setOnce() { self?.lock.withLock { self?.connections -= 1 } }
            default: break
            }
        }
        conn.start(queue: queue)
        let complete = Flag()
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) {
            if !complete.isSet { conn.cancel() }
        }
        receive(conn, source: source, buffer: Data(), complete: complete)
    }

    private func receive(_ conn: NWConnection, source: RequestSource, buffer: Data, complete: Flag) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPRequest.parse(buf) {
            case .incomplete:
                if done || error != nil { conn.cancel() } else { self.receive(conn, source: source, buffer: buf, complete: complete) }
            case .invalid(let why):
                _ = complete.setOnce()
                self.respond(conn, .error(400, why))
            case .complete(let req, _):
                _ = complete.setOnce()
                self.handle(req, conn: conn, source: source)
            }
        }
    }

    private func respond(_ conn: NWConnection, _ response: HTTPResponse) {
        conn.send(content: response.serialized, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func handle(_ req: HTTPRequest, conn: NWConnection, source: RequestSource) {
        let decision = lock.withLock { policy.decide(req, from: source) }
        let client: String?
        let token: String?
        switch decision {
        case .deny(let status, let reason):
            respond(conn, .error(status, reason))
            return
        case .allow(let c, let t):
            client = c
            token = t
        }
        switch router.route(req, client: client) {
        case .response(let r):
            respond(conn, r)
        case .stream(let filter, let lastID, let name):
            let via: String = switch source { case .socket: "socket"; case .loopback: "loopback"; case .network: "lan" }
            openStream(conn, filter: filter, lastID: lastID,
                       reader: Reader(name: name, via: via, since: Date(), token: token))
        }
    }

    // MARK: streams

    /// A thread-safe one-way flag.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        /// Sets the flag; true only for the call that set it.
        func setOnce() -> Bool { lock.withLock { defer { value = true }; return !value } }
    }

    /// One open stream. Live events that arrive while the replay is being sent are held
    /// and sent after it, so a client sees every event once and in order.
    final class Stream: @unchecked Sendable {
        let conn: NWConnection
        private let lock = NSLock()
        private var pending = 0
        private var closed = false
        private var replaying = true
        private var held: [Event] = []
        private var lastSent = Int.min
        var token: UUID?
        var timer: DispatchSourceTimer?
        var onDrop: (@Sendable () -> Void)?

        init(conn: NWConnection) { self.conn = conn }

        /// Writes bytes; false when the client has fallen too far behind.
        private func write(_ text: String) -> Bool {
            if closed { return true }
            if pending >= Server.maximumPendingSends { return false }
            pending += 1
            conn.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] err in
                guard let self else { return }
                self.lock.withLock { self.pending -= 1 }
                if err != nil { self.drop() }
            })
            return true
        }

        func sendHead() { lock.withLock { _ = write(SSE.responseHead) } }

        func keepAlive() {
            let ok = lock.withLock { write(SSE.keepAlive) }
            if !ok { drop() }
        }

        /// Sends the replay as one write, then the live events held meanwhile.
        func sendReplay(_ events: [Event]) {
            let ok: Bool = lock.withLock {
                var text = events.map(SSE.frame).joined()
                if let last = events.last?.id { lastSent = last }
                for e in held where e.id > lastSent {
                    text += SSE.frame(e)
                    lastSent = e.id
                }
                held = []
                replaying = false
                return text.isEmpty || write(text)
            }
            if !ok { drop() }
        }

        func deliver(_ e: Event) {
            let ok: Bool = lock.withLock {
                if replaying {
                    held.append(e)
                    return held.count < Server.maximumPendingSends
                }
                guard e.id > lastSent else { return true }
                lastSent = e.id
                return write(SSE.frame(e))
            }
            if !ok { drop() }
        }

        func drop() {
            let first: Bool = lock.withLock {
                if closed { return false }
                closed = true
                return true
            }
            guard first else { return }
            timer?.cancel()
            conn.cancel()
            onDrop?()
        }
    }

    private func openStream(_ conn: NWConnection, filter: StreamFilter, lastID: Int?, reader: Reader) {
        let stream = Stream(conn: conn)
        let key = ObjectIdentifier(stream)
        stream.sendHead()
        let hub = self.hub
        stream.onDrop = { [weak self, weak stream] in
            if let t = stream?.token { hub.unsubscribe(t) }
            guard let self else { return }
            self.lock.withLock {
                self.streams[key] = nil
                self.readers[key] = nil
            }
            self.onChange?()
        }
        lock.withLock {
            streams[key] = stream
            readers[key] = reader
        }
        // The connection count is released by accept's state handler; a failed or closed
        // connection ends the stream through watchForClose or a failed write.
        let (token, replay) = hub.subscribe(filter: filter, after: lastID) { [weak stream] event in
            stream?.deliver(event)
        }
        stream.token = token
        stream.sendReplay(replay)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.keepAliveInterval, repeating: Self.keepAliveInterval)
        timer.setEventHandler { [weak stream] in stream?.keepAlive() }
        stream.timer = timer
        timer.resume()
        watchForClose(conn, stream: stream)
        onChange?()
    }

    private func watchForClose(_ conn: NWConnection, stream: Stream) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak stream] _, _, done, error in
            guard let stream else { return }
            if done || error != nil { stream.drop() } else { self?.watchForClose(conn, stream: stream) }
        }
    }
}
