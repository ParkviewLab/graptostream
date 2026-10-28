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
    }

    public static let bonjourType = "_graptostream._tcp"
    /// A client that has this many unsent events is dropped; it catches up on reconnecting.
    public static let maximumPendingSends = 500
    public static let keepAliveInterval: TimeInterval = 15

    private let queue = DispatchQueue(label: "graptostream.server")
    private let hub: EventHub
    private let router: Router
    private let lock = NSLock()
    private var policy: AccessPolicy
    private var listeners: [NWListener] = []
    private var readers: [ObjectIdentifier: Reader] = [:]
    private var streams: [ObjectIdentifier: Stream] = [:]
    public private(set) var configuration: Configuration?
    /// Called on the server's queue when readers or listener state change.
    public var onChange: (@Sendable () -> Void)?
    /// The last error a listener reported, for the window to show.
    public private(set) var lastError: String?

    public init(hub: EventHub, router: Router, tokens: [ClientToken]) {
        self.hub = hub
        self.router = router
        self.policy = AccessPolicy(port: 0, tokens: tokens)
    }

    public func setTokens(_ tokens: [ClientToken]) {
        lock.lock()
        policy.tokens = tokens
        lock.unlock()
    }

    public func currentReaders() -> [Reader] {
        lock.lock()
        defer { lock.unlock() }
        return readers.values.sorted { $0.since < $1.since }
    }

    // MARK: listening

    public func start(_ config: Configuration) {
        stop()
        lock.lock()
        configuration = config
        policy.port = config.port
        lastError = nil
        lock.unlock()

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
        if !config.lan {
            tcpParams.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: config.port)!)
        }
        let tcp = config.lan ? try? NWListener(using: tcpParams, on: NWEndpoint.Port(rawValue: config.port)!)
                             : try? NWListener(using: tcpParams)
        if config.lan, let tcp {
            tcp.service = NWListener.Service(name: config.bonjourName, type: Self.bonjourType)
        }
        add(listener: tcp, source: { conn in Self.isLoopback(conn) ? .loopback : .network }, label: "tcp", onReady: {})
    }

    public func stop() {
        lock.lock()
        let ls = listeners
        listeners = []
        let ss = Array(streams.values)
        streams = [:]
        readers = [:]
        let path = configuration?.socketPath
        lock.unlock()
        for l in ls { l.cancel() }
        for s in ss { s.close() }
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
        lock.lock()
        listeners.append(listener)
        lock.unlock()
    }

    private func note(error: String) {
        lock.lock()
        lastError = error
        lock.unlock()
        onChange?()
    }

    static func isLoopback(_ conn: NWConnection) -> Bool {
        if case .hostPort(let host, _) = conn.endpoint {
            switch host {
            case .ipv4(let a): return a == .loopback || "\(a)".hasPrefix("127.")
            case .ipv6(let a): return a == .loopback || "\(a)" == "::ffff:127.0.0.1"
            case .name(let n, _): return n == "localhost"
            @unknown default: return false
            }
        }
        return false
    }

    // MARK: connections

    private func accept(_ conn: NWConnection, source: RequestSource) {
        conn.start(queue: queue)
        receive(conn, source: source, buffer: Data())
    }

    private func receive(_ conn: NWConnection, source: RequestSource, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPRequest.parse(buf) {
            case .incomplete:
                if done || error != nil { conn.cancel() } else { self.receive(conn, source: source, buffer: buf) }
            case .invalid(let why):
                self.respond(conn, .error(400, why))
            case .complete(let req, _):
                self.handle(req, conn: conn, source: source)
            }
        }
    }

    private func respond(_ conn: NWConnection, _ response: HTTPResponse) {
        conn.send(content: response.serialized, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func handle(_ req: HTTPRequest, conn: NWConnection, source: RequestSource) {
        lock.lock()
        let decision = policy.decide(req, from: source)
        lock.unlock()
        let client: String?
        switch decision {
        case .deny(let status, let reason):
            respond(conn, .error(status, reason))
            return
        case .allow(let c):
            client = c
        }
        switch router.route(req, client: client) {
        case .response(let r):
            respond(conn, r)
        case .stream(let filter, let lastID, let name):
            let via: String = switch source { case .socket: "socket"; case .loopback: "loopback"; case .network: "lan" }
            openStream(conn, filter: filter, lastID: lastID, reader: Reader(name: name, via: via, since: Date()))
        }
    }

    // MARK: streams

    final class Stream: @unchecked Sendable {
        let conn: NWConnection
        let lock = NSLock()
        var pending = 0
        var closed = false
        var token: UUID?
        var timer: DispatchSourceTimer?
        init(conn: NWConnection) { self.conn = conn }

        /// Sends bytes; false when the client has fallen too far behind.
        func send(_ text: String) -> Bool {
            lock.lock()
            if closed { lock.unlock(); return true }
            if pending >= Server.maximumPendingSends { lock.unlock(); return false }
            pending += 1
            lock.unlock()
            conn.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] err in
                guard let self else { return }
                self.lock.lock()
                self.pending -= 1
                self.lock.unlock()
                if err != nil { self.close() }
            })
            return true
        }

        func close() {
            lock.lock()
            if closed { lock.unlock(); return }
            closed = true
            lock.unlock()
            timer?.cancel()
            conn.cancel()
        }
    }

    private func openStream(_ conn: NWConnection, filter: StreamFilter, lastID: Int?, reader: Reader) {
        let stream = Stream(conn: conn)
        let key = ObjectIdentifier(stream)
        _ = stream.send(SSE.responseHead)
        lock.lock()
        streams[key] = stream
        readers[key] = reader
        lock.unlock()

        let drop: @Sendable () -> Void = { [weak self, weak stream] in
            guard let self, let stream else { return }
            if let t = stream.token { self.hub.unsubscribe(t) }
            stream.close()
            self.lock.lock()
            self.streams[key] = nil
            self.readers[key] = nil
            self.lock.unlock()
            self.onChange?()
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: drop()
            default: break
            }
        }
        stream.token = hub.subscribe(filter: filter, after: lastID) { [weak stream] event in
            guard let stream else { return }
            if !stream.send(SSE.frame(event)) { drop() }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.keepAliveInterval, repeating: Self.keepAliveInterval)
        timer.setEventHandler { [weak stream] in
            if let stream, !stream.send(SSE.keepAlive) { drop() }
        }
        stream.timer = timer
        timer.resume()
        // A client that closes its side ends the stream.
        watchForClose(conn, drop: drop)
        onChange?()
    }

    private func watchForClose(_ conn: NWConnection, drop: @escaping @Sendable () -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, error in
            if done || error != nil { drop() } else { self?.watchForClose(conn, drop: drop) }
        }
    }
}
