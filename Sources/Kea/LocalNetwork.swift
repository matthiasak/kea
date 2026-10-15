import Foundation

/// Addresses on this Mac or on the network it's on — where Settings › AI ›
/// Custom server may point. Anything else is the internet, and refused.
enum LocalNetwork {
    static func onThisMac(_ host: String) -> Bool {
        ["127.0.0.1", "::1", "localhost"].contains(bare(host))
    }

    /// Loopback, private and link-local IPv4, and .local / .home.arpa names.
    static func contains(_ host: String) -> Bool {
        let host = bare(host)
        if onThisMac(host) || host.hasSuffix(".local") || host.hasSuffix(".home.arpa") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = parts.compactMap { UInt8($0) }
        guard parts.count == 4, bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// What was typed in Settings, as a server's base address, ending in "/",
    /// or nil when it isn't http(s) on this Mac or your network.
    static func server(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let host = url.host(), contains(host)
        else { return nil }
        return url
    }

    private static func bare(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}
