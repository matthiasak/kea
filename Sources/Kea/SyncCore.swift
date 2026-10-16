import CommonCrypto
import CryptoKit
import Foundation

// Sync's parts that need nothing of the app's: where its files go, how each is sealed, and how two Macs' records are weighed.

/// One place every Mac reads and writes, by name: "kea/v1/devices/<uuid>/bookmarks.kea".
protocol SyncDrop: Sendable {
    /// Every name under `prefix` (which ends in "/"), with when it last changed.
    func list(_ prefix: String) async throws -> [String: Date]
    /// Nil when nothing has that name.
    func get(_ name: String) async throws -> Data?
    func put(_ name: String, _ data: Data) async throws
    func delete(_ name: String) async throws
}

enum SyncError: LocalizedError, Equatable {
    case missing(String)
    case refused(Int)
    case unreachable(String)
    case wrongPassphrase
    case damaged

    var errorDescription: String? {
        switch self {
        case .missing(let path):
            return "The folder \(path) isn't there"
        case .refused(let code):
            return (code == 401 || code == 403)
                ? "The bucket refused the key" : "The bucket answered \(code)"
        case .unreachable(let host):
            return "Can't reach \(host)"
        case .wrongPassphrase:
            return "That passphrase doesn't open this sync folder"
        case .damaged:
            return "A file in the sync store couldn't be read"
        }
    }
}

struct FolderDrop: SyncDrop {
    let root: URL

    private static func checkRoot(_ root: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
            isDir.boolValue
        else {
            throw SyncError.missing(root.path)
        }
    }

    func list(_ prefix: String) async throws -> [String: Date] {
        let root = self.root
        return try await Task.detached {
            try Self.checkRoot(root)
            let clean = prefix.hasSuffix("/") ? prefix : prefix + "/"
            let dir = root.appendingPathComponent(clean, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                isDir.boolValue
            else {
                return [:]
            }
            let baseDir = dir.resolvingSymlinksInPath()
            let basePrefix = baseDir.path.hasSuffix("/") ? baseDir.path : baseDir.path + "/"
            guard
                let items = FileManager.default.enumerator(
                    at: baseDir,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            else { return [:] }
            var result: [String: Date] = [:]
            while let url = items.nextObject() as? URL {
                let vals = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .contentModificationDateKey,
                ])
                guard vals?.isRegularFile == true else { continue }
                let full = url.resolvingSymlinksInPath().path
                guard full.hasPrefix(basePrefix) else { continue }
                let rel = String(full.dropFirst(basePrefix.count))
                result[clean + rel] =
                    vals?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            }
            return result
        }.value
    }

    func get(_ name: String) async throws -> Data? {
        let root = self.root
        return try await Task.detached {
            try Self.checkRoot(root)
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }.value
    }

    func put(_ name: String, _ data: Data) async throws {
        let root = self.root
        try await Task.detached {
            try Self.checkRoot(root)
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }.value
    }

    func delete(_ name: String) async throws {
        let root = self.root
        try await Task.detached {
            try Self.checkRoot(root)
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try? FileManager.default.removeItem(at: url)
        }.value
    }
}

struct BucketDrop: SyncDrop {
    let endpoint: URL
    let bucket: String
    let access: String
    let secret: String
    var region = "auto"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    static func allowed(_ endpoint: URL) -> Bool {
        guard let scheme = endpoint.scheme?.lowercased(), let host = endpoint.host(), !host.isEmpty
        else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && LocalNetwork.onThisMac(host)
    }

    private func baseURLString() -> String {
        var s = endpoint.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func objectURL(_ name: String) throws -> URL {
        let encodedBucket = SigV4.uriEncode(bucket, encodeSlash: true)
        let encodedName = name.split(separator: "/", omittingEmptySubsequences: false)
            .map { SigV4.uriEncode(String($0), encodeSlash: true) }
            .joined(separator: "/")
        let raw = "\(baseURLString())/\(encodedBucket)/\(encodedName)"
        guard let url = URL(string: raw) else {
            throw SyncError.unreachable(endpoint.host() ?? raw)
        }
        return url
    }

    private func listURL(prefix: String, token: String?) throws -> URL {
        let encodedBucket = SigV4.uriEncode(bucket, encodeSlash: true)
        var query = "list-type=2&prefix=\(SigV4.uriEncode(prefix, encodeSlash: true))"
        if let token, !token.isEmpty {
            query += "&continuation-token=\(SigV4.uriEncode(token, encodeSlash: true))"
        }
        let raw = "\(baseURLString())/\(encodedBucket)?\(query)"
        guard let url = URL(string: raw) else {
            throw SyncError.unreachable(endpoint.host() ?? raw)
        }
        return url
    }

    private func send(method: String, url: URL, body: Data? = nil) async throws -> (Int, Data) {
        let now = Date()
        let host = endpoint.host() ?? ""
        let defaultPort = endpoint.scheme?.lowercased() == "https" ? 443 : 80
        let hostHeader: String
        if let port = endpoint.port, port != defaultPort {
            hostHeader = "\(host):\(port)"
        } else {
            hostHeader = host
        }
        let payloadHash = SyncMerge.hash(body ?? Data())
        let amzDate = SigV4.amzDate(now)
        let headers = [
            "host": hostHeader,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate,
        ]
        let auth = SigV4.authorization(
            method: method,
            url: url,
            headers: headers,
            payloadHash: payloadHash,
            access: access,
            secret: secret,
            region: region,
            date: now
        )
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue(auth, forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await Self.session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (code, data)
        } catch {
            throw SyncError.unreachable(host.isEmpty ? endpoint.absoluteString : host)
        }
    }

    func get(_ name: String) async throws -> Data? {
        let (code, data) = try await send(method: "GET", url: try objectURL(name))
        if code == 200 { return data }
        if code == 404 { return nil }
        throw SyncError.refused(code)
    }

    func put(_ name: String, _ data: Data) async throws {
        let (code, _) = try await send(method: "PUT", url: try objectURL(name), body: data)
        guard (200..<300).contains(code) else { throw SyncError.refused(code) }
    }

    func delete(_ name: String) async throws {
        let (code, _) = try await send(method: "DELETE", url: try objectURL(name))
        guard (200..<300).contains(code) || code == 404 else { throw SyncError.refused(code) }
    }

    func list(_ prefix: String) async throws -> [String: Date] {
        var all: [String: Date] = [:]
        var token: String?
        repeat {
            let (code, data) = try await send(
                method: "GET", url: try listURL(prefix: prefix, token: token))
            guard code == 200 else { throw SyncError.refused(code) }
            let page = Self.listing(data)
            for (k, v) in page.names { all[k] = v }
            token = page.next
        } while token != nil
        return all
    }

    static func listing(_ xml: Data) -> (names: [String: Date], next: String?) {
        final class Parser: NSObject, XMLParserDelegate {
            var names: [String: Date] = [:]
            var next: String?
            private var inContents = false
            private var text = ""
            private var currentKey: String?
            private var currentDate: Date?

            private static func parseDate(_ raw: String) -> Date? {
                let frac = ISO8601DateFormatter()
                frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = frac.date(from: raw) { return d }
                let plain = ISO8601DateFormatter()
                plain.formatOptions = [.withInternetDateTime]
                return plain.date(from: raw)
            }

            private static func bare(_ name: String) -> String {
                name.split(separator: ":").last.map(String.init) ?? name
            }

            func parser(
                _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
            ) {
                let tag = Self.bare(elementName)
                text = ""
                if tag == "Contents" {
                    inContents = true
                    currentKey = nil
                    currentDate = nil
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                text += string
            }

            func parser(
                _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?
            ) {
                let tag = Self.bare(elementName)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if inContents {
                    if tag == "Key" {
                        currentKey = trimmed
                    } else if tag == "LastModified" {
                        currentDate = Self.parseDate(trimmed)
                    } else if tag == "Contents" {
                        if let k = currentKey, !k.isEmpty, let d = currentDate {
                            names[k] = d
                        }
                        inContents = false
                    }
                } else if tag == "NextContinuationToken", !trimmed.isEmpty {
                    next = trimmed
                }
                text = ""
            }
        }
        let delegate = Parser()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        _ = parser.parse()
        return (delegate.names, delegate.next)
    }
}

enum SigV4 {
    private static let unreserved: Set<UInt8> = {
        var set = Set<UInt8>()
        for b in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(b) }
        for b in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(b) }
        for b in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(b) }
        for c in "-_.~".utf8 { set.insert(c) }
        return set
    }()

    static func uriEncode(_ string: String, encodeSlash: Bool) -> String {
        var out = ""
        for byte in string.utf8 {
            if unreserved.contains(byte) || (!encodeSlash && byte == UInt8(ascii: "/")) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func amzDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func authorization(
        method: String,
        url: URL,
        headers: [String: String],
        payloadHash: String,
        access: String,
        secret: String,
        region: String,
        service: String = "s3",
        date: Date
    ) -> String {
        let amz = amzDate(date)
        let shortDate = String(amz.prefix(8))

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let rawPath = components?.percentEncodedPath ?? ""
        let canonicalPath = rawPath.isEmpty ? "/" : rawPath

        let canonicalQuery: String
        if let items = components?.queryItems, !items.isEmpty {
            let pairs: [(String, String)] = items.map { item in
                (uriEncode(item.name, encodeSlash: true), uriEncode(item.value ?? "", encodeSlash: true))
            }
            let encoded = pairs.sorted { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
            canonicalQuery = encoded.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        } else {
            canonicalQuery = ""
        }

        let headerPairs: [(String, String)] = headers.map {
            ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces))
        }
        let sortedHeaders = headerPairs.sorted { $0.0 < $1.0 }
        let canonicalHeaders = sortedHeaders.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = sortedHeaders.map(\.0).joined(separator: ";")

        let canonicalRequest = [
            method,
            canonicalPath,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(shortDate)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amz,
            scope,
            SyncMerge.hash(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let kSecret = SymmetricKey(data: Data(("AWS4" + secret).utf8))
        let kDate = HMAC<SHA256>.authenticationCode(for: Data(shortDate.utf8), using: kSecret)
        let kRegion = HMAC<SHA256>.authenticationCode(
            for: Data(region.utf8), using: SymmetricKey(data: kDate))
        let kService = HMAC<SHA256>.authenticationCode(
            for: Data(service.utf8), using: SymmetricKey(data: kRegion))
        let kSigning = HMAC<SHA256>.authenticationCode(
            for: Data("aws4_request".utf8), using: SymmetricKey(data: kService))
        let sig = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8), using: SymmetricKey(data: kSigning))
        let sigHex = sig.map { String(format: "%02x", $0) }.joined()

        return
            "AWS4-HMAC-SHA256 Credential=\(access)/\(scope),SignedHeaders=\(signedHeaders),Signature=\(sigHex)"
    }
}

enum SyncSeal {
    static let iterations: UInt32 = 600_000

    static func key(passphrase: String, salt: Data) -> SymmetricKey {
        let pass = Array(passphrase.utf8)
        let saltBytes = Array(salt)
        var derived = [UInt8](repeating: 0, count: 32)
        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            pass, pass.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            iterations,
            &derived, derived.count
        )
        return SymmetricKey(data: Data(derived))
    }

    static func seal(_ data: Data, with key: SymmetricKey) throws -> Data {
        do {
            let compressed = try (data as NSData).compressed(using: .zlib) as Data
            guard let combined = try AES.GCM.seal(compressed, using: key).combined else {
                throw SyncError.damaged
            }
            return combined
        } catch {
            throw SyncError.damaged
        }
    }

    static func open(_ data: Data, with key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let compressed = try AES.GCM.open(box, using: key)
            return try (compressed as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw SyncError.damaged
        }
    }
}

struct SyncMark: Codable, Equatable {
    var hash: String
    var at: Date
}

struct SyncRecord: Codable, Equatable {
    var data: Data
    var at: Date
}

struct SyncDoc: Codable, Equatable {
    var records: [String: SyncRecord] = [:]
    var gone: [String: Date] = [:]
}

struct SyncLedger: Codable, Equatable {
    var marks: [String: SyncMark] = [:]
    var gone: [String: Date] = [:]
}

enum SyncMerge {
    static let keepGone: TimeInterval = 90 * 86_400

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func stamp(_ current: [String: Data], into ledger: inout SyncLedger, now: Date) {
        for (key, data) in current {
            let h = hash(data)
            if ledger.marks[key]?.hash != h {
                ledger.marks[key] = SyncMark(hash: h, at: now)
            }
            ledger.gone[key] = nil
        }
        for key in Array(ledger.marks.keys) where current[key] == nil {
            ledger.marks[key] = nil
            ledger.gone[key] = now
        }
        let cutoff = now.addingTimeInterval(-keepGone)
        ledger.gone = ledger.gone.filter { $0.value >= cutoff }
    }

    static func take(_ doc: SyncDoc, against ledger: SyncLedger) -> (
        put: [String: SyncRecord], remove: [String: Date]
    ) {
        var put: [String: SyncRecord] = [:]
        for (key, remote) in doc.records {
            let mark = ledger.marks[key]
            let markAt = mark?.at ?? .distantPast
            let goneAt = ledger.gone[key] ?? .distantPast
            if remote.at > markAt && remote.at > goneAt {
                put[key] = remote
            } else if let mark, remote.at == mark.at, hash(remote.data) > mark.hash {
                put[key] = remote
            }
        }
        var remove: [String: Date] = [:]
        for (key, goneAt) in doc.gone {
            if let mark = ledger.marks[key], goneAt > mark.at {
                remove[key] = goneAt
            }
        }
        return (put, remove)
    }

    static func settle(
        _ key: String, local: Data?, remote: SyncRecord, in ledger: inout SyncLedger, now: Date
    ) {
        ledger.gone[key] = nil
        guard let local else {
            ledger.marks[key] = nil
            return
        }
        let localHash = hash(local)
        if localHash == hash(remote.data) {
            ledger.marks[key] = SyncMark(hash: localHash, at: remote.at)
        } else {
            ledger.marks[key] = SyncMark(hash: localHash, at: now)
        }
    }

    static func removed(_ key: String, at: Date, in ledger: inout SyncLedger) {
        ledger.marks[key] = nil
        ledger.gone[key] = at
    }

    static func doc(_ current: [String: Data], ledger: SyncLedger, now: Date) -> SyncDoc {
        var records: [String: SyncRecord] = [:]
        for (key, data) in current {
            if let mark = ledger.marks[key] {
                records[key] = SyncRecord(data: data, at: mark.at)
            }
        }
        let cutoff = now.addingTimeInterval(-keepGone)
        let gone = ledger.gone.filter { $0.value >= cutoff }
        return SyncDoc(records: records, gone: gone)
    }
}
