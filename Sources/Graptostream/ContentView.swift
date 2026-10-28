// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import GraptostreamCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stateLine
            if let e = model.lastError ?? model.serverError {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            HStack(alignment: .top, spacing: 16) {
                microphones.frame(maxWidth: .infinity)
                clients.frame(maxWidth: .infinity)
            }
            recentText
        }
        .padding(20)
    }

    private var stateLine: some View {
        HStack(spacing: 10) {
            Circle().fill(model.listening ? Color.green : Color.secondary.opacity(0.4)).frame(width: 12, height: 12)
            Text(model.reason).font(.headline)
            Spacer()
            Picker("Listen", selection: $model.settings.mode) {
                ForEach(ListenMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
        }
    }

    private var microphones: some View {
        GroupBox("Microphones") {
            VStack(alignment: .leading, spacing: 8) {
                if model.feedURL != nil {
                    Text("Reading \(model.feedURL!.lastPathComponent) instead of the microphones.").font(.caption).foregroundStyle(.secondary)
                }
                if model.devices.isEmpty { Text("No input devices.").foregroundStyle(.secondary) }
                ForEach(model.devices) { d in
                    HStack {
                        Toggle(isOn: Binding(get: { model.isSelected(d) }, set: { model.setSelected(d, $0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name)
                                if d.isBluetooth {
                                    Text("Bluetooth: listens only on request").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        LevelMeter(level: model.levels[d.uid] ?? 0).frame(width: 90, height: 8)
                    }
                }
                if model.permission == .denied || model.permission == .restricted {
                    Text("Microphone access is denied. Allow it in System Settings › Privacy & Security › Microphone.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var clients: some View {
        GroupBox("Clients") {
            VStack(alignment: .leading, spacing: 8) {
                if model.readers.isEmpty && model.requests.isEmpty {
                    Text("No clients connected.").foregroundStyle(.secondary)
                }
                ForEach(clientNames, id: \.self) { name in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                        Text(describe(name)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var clientNames: [String] {
        var seen: [String] = []
        for n in model.readers.map(\.name) + model.requests.map(\.client) where !seen.contains(n) { seen.append(n) }
        return seen
    }

    private func describe(_ name: String) -> String {
        var parts: [String] = []
        let reading = model.readers.filter { $0.name == name }
        if !reading.isEmpty { parts.append("reading the stream (\(Set(reading.map(\.via)).sorted().joined(separator: ", ")))") }
        if let r = model.requests.filter({ $0.client == name }).max(by: { $0.expires < $1.expires }) {
            parts.append("asked to listen until \(r.expires.formatted(date: .omitted, time: .standard))")
        }
        return parts.joined(separator: "; ")
    }

    private var recentText: some View {
        GroupBox("Recent text") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.recent, id: \.seg) { s in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(s.end.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                if let to = s.to {
                                    Text("→ \(to)").font(.caption.bold()).foregroundStyle(Color.accentColor)
                                }
                                Text(s.full).textSelection(.enabled)
                            }
                            .id(s.seg)
                        }
                        if let p = model.provisional {
                            Text(p.text).foregroundStyle(.secondary).italic().id("provisional")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .onChange(of: model.recent.count) { _, _ in proxy.scrollTo(model.recent.last?.seg, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct LevelMeter: View {
    var level: Float

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(level > 0.85 ? Color.orange : Color.green)
                    .frame(width: g.size.width * CGFloat(level))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
