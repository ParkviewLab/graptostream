// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import GraptostreamCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            NamesTab(model: model).tabItem { Label("Spoken names", systemImage: "person.wave.2") }
            NetworkTab(model: model).tabItem { Label("Network", systemImage: "network") }
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 420)
        .padding(16)
    }
}

struct NamesTab: View {
    @Bindable var model: AppModel
    @State private var name = ""
    @State private var app = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("An utterance that begins with a spoken name is addressed to its app. Ordinary, distinct words work best; the speech engine mishears invented names.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(model.settings.names) { n in
                    HStack {
                        Text(n.name).frame(width: 160, alignment: .leading)
                        Text("→ \(n.app)").foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            model.settings.names.removeAll { $0.id == n.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                TextField("Spoken name (e.g. Fred)", text: $name)
                TextField("App (e.g. scrinotia)", text: $app)
                Button("Add") {
                    let n = name.trimmingCharacters(in: .whitespaces), a = app.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty, !a.isEmpty else { return }
                    model.settings.names.removeAll { $0.id == n.lowercased() }
                    model.settings.names.append(SpokenName(name: n, app: a))
                    name = ""; app = ""
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || app.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct NetworkTab: View {
    @Bindable var model: AppModel
    @State private var tokenName = ""

    var body: some View {
        Form {
            Section {
                Toggle("Serve the stream to other machines on the LAN", isOn: $model.settings.lan)
                TextField("Port", value: $model.settings.port, format: .number.grouping(.never))
                    .frame(width: 160)
                Text("Local clients use the socket at \(model.socketPath) or http://127.0.0.1:\(String(model.settings.port)). LAN clients use http://\(ProcessInfo.processInfo.hostName):\(String(model.settings.port)) with a token below, and can find the service by Bonjour.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Tokens for LAN clients") {
                ForEach(model.settings.tokens) { t in
                    HStack {
                        Text(t.name)
                        Text("since \(t.created.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.secondary)
                        Spacer()
                        Button("Revoke", role: .destructive) { model.revokeToken(t) }
                    }
                }
                HStack {
                    TextField("Client name (e.g. vision-pro)", text: $tokenName)
                    Button("Issue token") {
                        model.issueToken(named: tokenName.trimmingCharacters(in: .whitespaces))
                        tokenName = ""
                    }
                    .disabled(tokenName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let s = model.newSecret {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Token for \(s.name), shown once:").font(.caption)
                        HStack {
                            Text(s.secret).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(s.secret, forType: .string)
                            }
                            Button("Done") { model.newSecret = nil }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Toggle("Start graptostream at login", isOn: Binding(get: { model.launchAtLogin },
                                                                 set: { model.setLaunchAtLogin($0) }))
            Stepper("Keep the transcript for \(model.settings.retentionDays) days",
                    value: $model.settings.retentionDays, in: 1...3650)
            Stepper("End a segment after \(Int(model.settings.maximumSegmentSeconds)) s without a pause",
                    value: $model.settings.maximumSegmentSeconds, in: 10...120, step: 5)
            LabeledContent("Transcript folder") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.store.directory])
                }
            }
            LabeledContent("Speech model") {
                switch model.modelState {
                case .unknown: Text("not checked")
                case .installing: Text("installing…")
                case .ready: Text("ready (en-US)")
                case .failed(let e): Text("unavailable: \(e)").foregroundStyle(.orange)
                }
            }
            LabeledContent("Version") { Text(model.version) }
        }
        .formStyle(.grouped)
    }
}
