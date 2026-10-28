// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import GraptostreamCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.launch() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }

    /// Closing the window keeps the app running and listening; Quit stops it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct GraptostreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("graptostream", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 620, minHeight: 560)
        }
        .defaultSize(width: 760, height: 680)

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.listening ? "waveform.circle.fill" : "waveform.circle")
        }
    }
}

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.reason)
        Divider()
        Picker("Listen", selection: $model.settings.mode) {
            ForEach(ListenMode.allCases) { Text($0.label).tag($0) }
        }
        Button("Show Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit graptostream") { NSApp.terminate(nil) }
    }
}
