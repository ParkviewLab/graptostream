// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import GraptostreamCore
import SwiftUI

@main
struct GraptostreamApp: App {
    var body: some Scene {
        Window("graptostream", id: "main") {
            Text("graptostream \(AppVersion.current())")
                .padding(40)
        }
    }
}
