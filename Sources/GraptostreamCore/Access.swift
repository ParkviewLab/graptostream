// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

/// Where a request came from, which decides what it must show to be served.
public enum RequestSource: Sendable, Equatable {
    /// The Unix socket: only the owner's processes can open it.
    case socket
    /// The loopback address: any process on this Mac, and a browser's pages.
    case loopback
    /// Another machine on the LAN.
    case network
}

/// A token issued to a LAN client. Only its hash is kept.
public struct ClientToken: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var hash: String
    public var created: Date

    public static func make(name: String, now: Date = Date()) -> (token: ClientToken, secret: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        let secret = "gs_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = ClientToken(id: UUID().uuidString.lowercased(), name: name, hash: Self.hash(secret), created: now)
        return (token, secret)
    }

    public static func hash(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The access rules: the Host and Origin check on loopback, a token on the LAN.
public struct AccessPolicy: Sendable {
    public var port: UInt16
    public var tokens: [ClientToken]

    public init(port: UInt16, tokens: [ClientToken]) {
        self.port = port
        self.tokens = tokens
    }

    public enum Decision: Sendable, Equatable {
        /// Served, on behalf of this client name (a token's name, or nil when local), and,
        /// for a LAN client, the id of the token it showed.
        case allow(client: String?, token: String? = nil)
        case deny(status: Int, reason: String)
    }

    var localHosts: Set<String> {
        ["localhost", "127.0.0.1", "[::1]", "localhost:\(port)", "127.0.0.1:\(port)", "[::1]:\(port)"]
    }

    var localOrigins: Set<String> {
        ["http://localhost:\(port)", "http://127.0.0.1:\(port)", "http://[::1]:\(port)"]
    }

    /// A browser's `Host` is the name it used, so a page that has rebound a domain to
    /// 127.0.0.1 fails the Host check. A cross-site page's request carries `Origin` (for
    /// anything but a simple GET) or `Sec-Fetch-Site: cross-site` (current browsers, every
    /// request, an `<img>` included), and either refuses it.
    public func decide(_ request: HTTPRequest, from source: RequestSource) -> Decision {
        switch source {
        case .socket:
            return .allow(client: nil)
        case .loopback:
            guard let host = request.header("host")?.lowercased(), localHosts.contains(host) else {
                return .deny(status: 403, reason: "Host must be localhost or 127.0.0.1")
            }
            if let o = request.header("origin")?.lowercased(), !localOrigins.contains(o) {
                return .deny(status: 403, reason: "cross-origin requests are not accepted")
            }
            if let site = request.header("sec-fetch-site")?.lowercased(), site != "same-origin", site != "none" {
                return .deny(status: 403, reason: "cross-site requests are not accepted")
            }
            return .allow(client: nil)
        case .network:
            guard let auth = request.header("authorization"), auth.lowercased().hasPrefix("bearer ") else {
                return .deny(status: 401, reason: "a bearer token is required")
            }
            let secret = String(auth.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
            let h = ClientToken.hash(secret)
            guard let t = tokens.first(where: { constantTimeEqual($0.hash, h) }) else {
                return .deny(status: 401, reason: "unknown token")
            }
            return .allow(client: t.name, token: t.id)
        }
    }

    func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
