// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation
import GraptostreamCore
import Observation
import ServiceManagement

/// Listening modes: on request, always, or never.
enum ListenMode: String, CaseIterable, Identifiable, Codable {
    case auto, always, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "When asked"
        case .always: "Always"
        case .off: "Off"
        }
    }
}

/// The settings, kept in UserDefaults.
struct AppSettings: Codable, Equatable {
    var selected: [String] = []
    var mode: ListenMode = .auto
    var names: [SpokenName] = []
    var retentionDays = 30
    var port: UInt16 = 35860
    var lan = false
    var tokens: [ClientToken] = []
    var maximumSegmentSeconds = 30.0

    static let key = "settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// The part of the app the server reads from its own queue: a locked snapshot.
final class Backend: ServiceBackend, @unchecked Sendable {
    let requests = ListenRequests()
    let store: TranscriptStore
    private let lock = NSLock()
    private var snapshot: ServiceStatus
    var onRequestsChanged: (@Sendable () -> Void)?

    init(store: TranscriptStore, version: String) {
        self.store = store
        snapshot = ServiceStatus(version: version, listening: false, reason: "starting", mode: "auto", microphones: [],
                                 readers: [], requests: [])
    }

    func update(_ s: ServiceStatus) {
        lock.lock()
        snapshot = s
        lock.unlock()
    }

    func status() -> ServiceStatus {
        lock.lock()
        var s = snapshot
        lock.unlock()
        s.requests = requests.active()
        return s
    }

    func requestsChanged() { onRequestsChanged?() }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var settings: AppSettings { didSet { if settings != oldValue { settings.save(); settingsChanged(from: oldValue) } } }
    var devices: [InputDevice] = []
    var levels: [String: Float] = [:]
    var listening = false
    var reason = "starting"
    var permission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    var modelState: Recognizer.ModelState = .unknown
    var recent: [Segment] = []
    var provisional: Segment?
    var readers: [Server.Reader] = []
    var requests: [ListenRequest] = []
    var serverError: String?
    var lastError: String?
    /// A token secret just issued, shown once.
    var newSecret: (name: String, secret: String)?
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    let version = AppVersion.current()
    let dataDirectory: URL
    let socketPath: String
    let store: TranscriptStore
    let hub: EventHub
    let backend: Backend
    let server: Server
    let addresser = Addresser()
    let capture = AudioCapture()
    let feed = FileFeed()
    let recognizer = Recognizer()
    let feedURL: URL?

    private var activeDevices: [String] = []
    private var stopWatching: (() -> Void)?
    private var tick: Timer?
    private var sweep: Timer?
    private var transitioning = false

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("graptostream", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        dataDirectory = support
        socketPath = support.appendingPathComponent("stream.sock").path
        store = TranscriptStore(directory: support.appendingPathComponent("transcript", isDirectory: true))
        hub = EventHub(store: store)
        backend = Backend(store: store, version: AppVersion.current())
        settings = AppSettings.load()
        server = Server(hub: hub, router: Router(backend: backend, version: AppVersion.current()), tokens: AppSettings.load().tokens)
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--feed"), i + 1 < args.count {
            feedURL = URL(fileURLWithPath: args[i + 1])
        } else {
            feedURL = nil
        }
        wire()
    }

    // MARK: setup

    private func wire() {
        addresser.setNames(settings.names)
        recognizer.maximumSegmentSeconds = settings.maximumSegmentSeconds
        let hub = self.hub
        let addresser = self.addresser
        recognizer.onSegment = { seg in
            var seg = seg
            if seg.state == .final {
                let a = addresser.address(seg.text, at: seg.end)
                seg.full = seg.text
                seg.text = a.text
                seg.to = a.to
                seg.heard = a.heard
            }
            hub.publish(seg)
        }
        recognizer.onError = { msg in Task { @MainActor in AppModel.shared.lastError = msg } }
        _ = hub.subscribe(filter: .init(), after: nil) { event in
            Task { @MainActor in AppModel.shared.received(event.segment) }
        }
        capture.onLevels = { levels in Task { @MainActor in AppModel.shared.levels = levels } }
        let recognizer = self.recognizer
        capture.onAudio = { recognizer.feed($0) }
        feed.onAudio = { recognizer.feed($0) }
        capture.onInterrupted = { why in Task { @MainActor in AppModel.shared.restartCapture(because: why) } }
        backend.onRequestsChanged = { Task { @MainActor in AppModel.shared.evaluate() } }
        server.onChange = { Task { @MainActor in AppModel.shared.refreshServerState() } }
    }

    /// Called once the window is up.
    func launch() {
        refreshDevices()
        stopWatching = AudioDevices.watch { Task { @MainActor in AppModel.shared.refreshDevices() } }
        startServer()
        store.sweep(retentionDays: settings.retentionDays)
        sweep = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.store.sweep(retentionDays: AppModel.shared.settings.retentionDays) }
        }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.evaluate() }
        }
        Task {
            modelState = .installing
            modelState = await recognizer.prepareModel()
            evaluate()
        }
    }

    func shutdown() {
        tick?.invalidate()
        sweep?.invalidate()
        stopWatching?()
        capture.stop()
        feed.stop()
        server.stop()
    }

    private func startServer() {
        server.setTokens(settings.tokens)
        server.start(.init(socketPath: socketPath, port: settings.port, lan: settings.lan,
                           bonjourName: settings.lan ? "graptostream on \(Host.current().localizedName ?? "this Mac")" : nil))
        refreshServerState()
    }

    private func settingsChanged(from old: AppSettings) {
        if settings.names != old.names { addresser.setNames(settings.names) }
        if settings.tokens != old.tokens { server.setTokens(settings.tokens) }
        if settings.port != old.port || settings.lan != old.lan { startServer() }
        recognizer.maximumSegmentSeconds = settings.maximumSegmentSeconds
        if settings.retentionDays != old.retentionDays { store.sweep(retentionDays: settings.retentionDays) }
        evaluate(force: settings.selected != old.selected)
    }

    // MARK: devices and listening

    func refreshDevices() {
        devices = AudioDevices.inputs()
        evaluate(force: Set(activeDevices) != Set(wantedDevices().map(\.uid)))
    }

    func isSelected(_ d: InputDevice) -> Bool { settings.selected.contains(d.uid) }

    func setSelected(_ d: InputDevice, _ on: Bool) {
        var s = settings.selected.filter { $0 != d.uid }
        if on { s.append(d.uid) }
        settings.selected = s
    }

    /// The selected devices that are present; Bluetooth inputs only while a request is live.
    private func wantedDevices() -> [InputDevice] {
        let live = !backend.requests.active().isEmpty
        return settings.selected.compactMap { uid in devices.first { $0.uid == uid } }
            .filter { !$0.isBluetooth || live }
    }

    /// Decides whether to listen, and starts or stops accordingly.
    func evaluate(force: Bool = false) {
        requests = backend.requests.active()
        let live = !requests.isEmpty
        let wanted = feedURL == nil ? wantedDevices() : []
        var should: Bool
        var why: String
        switch settings.mode {
        case .off:
            should = false; why = "Off"
        case .always:
            should = true; why = "Listening: set to always"
        case .auto:
            should = live
            why = live ? "Listening: requested by \(Set(requests.map(\.client)).count) client\(Set(requests.map(\.client)).count == 1 ? "" : "s")"
                       : "Not listening: no requests"
        }
        if should, feedURL == nil, wanted.isEmpty { should = false; why = "Not listening: no microphone selected" }
        if should, modelState != .ready {
            should = false
            why = modelState == .installing ? "Not listening: installing the speech model" : "Not listening: the speech model is unavailable"
        }
        if should, feedURL == nil, permission != .authorized {
            if permission == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    Task { @MainActor in
                        AppModel.shared.permission = AVCaptureDevice.authorizationStatus(for: .audio)
                        AppModel.shared.evaluate(force: true)
                    }
                }
            }
            should = false
            why = "Not listening: microphone access is not granted"
        }
        if feedURL != nil, should { why += " (from \(feedURL!.lastPathComponent))" }
        reason = why
        let deviceSetChanged = Set(wanted.map(\.uid)) != Set(activeDevices)
        if should != listening || (should && (force || deviceSetChanged)) {
            Task { await self.apply(listen: should, devices: wanted) }
        }
        publishSnapshot()
    }

    private func apply(listen: Bool, devices: [InputDevice]) async {
        guard !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        capture.stop()
        feed.stop()
        if !listen {
            await recognizer.stop()
            listening = false
            activeDevices = []
            provisional = nil
            publishSnapshot()
            return
        }
        do {
            if !listening { try await recognizer.start() }
            if let feedURL {
                feed.start(feedURL)
            } else {
                try capture.start(devices)
            }
            activeDevices = devices.map(\.uid)
            listening = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            await recognizer.stop()
            listening = false
            activeDevices = []
        }
        publishSnapshot()
    }

    func restartCapture(because why: String) {
        guard listening else { return }
        lastError = "Restarted capture: \(why)"
        evaluate(force: true)
    }

    // MARK: events, server state, status

    private func received(_ seg: Segment) {
        if seg.state == .provisional {
            provisional = seg
        } else {
            if provisional?.seg == seg.seg { provisional = nil }
            recent.append(seg)
            if recent.count > 50 { recent.removeFirst(recent.count - 50) }
        }
    }

    func refreshServerState() {
        readers = server.currentReaders()
        serverError = server.lastError
        publishSnapshot()
    }

    private func publishSnapshot() {
        backend.update(ServiceStatus(
            version: version, listening: listening, reason: reason, mode: settings.mode.rawValue,
            microphones: devices.map { .init(uid: $0.uid, name: $0.name, selected: isSelected($0), bluetooth: $0.isBluetooth) },
            readers: readers.map { .init(name: $0.name, via: $0.via, since: $0.since) },
            requests: []))
    }

    // MARK: tokens, names, login

    func issueToken(named name: String) {
        let (token, secret) = ClientToken.make(name: name)
        settings.tokens.append(token)
        newSecret = (name, secret)
    }

    func revokeToken(_ t: ClientToken) {
        settings.tokens.removeAll { $0.id == t.id }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
