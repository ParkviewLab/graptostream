// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import GraptostreamCore

@Test func versionFallsBackWhenTheBundleHasNone() {
    // A test runner's bundle carries no CFBundleShortVersionString of the app's.
    let version = AppVersion.current(in: Bundle(for: Marker.self))
    #expect(!version.isEmpty)
}

private final class Marker {}
