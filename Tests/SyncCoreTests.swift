import CryptoKit
import Darwin
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case check(String)

    var description: String {
        switch self {
        case .check(let message): message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.check(message) }
}

@main
private struct SyncCoreTests {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        // 1. FolderDrop in a temp root
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kea-folderdrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let drop = FolderDrop(root: tempRoot)
        let sampleName = "kea/v1/devices/abc/bookmarks.kea"
        let sampleBytes = Data("hello-kea".utf8)
        try await drop.put(sampleName, sampleBytes)
        let listed = try await drop.list("kea/v1/devices/")
        try require(listed[sampleName] != nil, "FolderDrop.list should find written object")
        let fetched = try await drop.get(sampleName)
        try require(fetched == sampleBytes, "FolderDrop.get should round-trip bytes")
        let absent = try await drop.get("kea/v1/devices/abc/missing.kea")
        try require(absent == nil, "FolderDrop.get missing should return nil")
        try await drop.delete(sampleName)
        let afterDelete = try await drop.get(sampleName)
        try require(afterDelete == nil, "FolderDrop.delete should remove object")

        let missingDrop = FolderDrop(root: tempRoot.appendingPathComponent("does-not-exist"))
        var threwMissing = false
        do {
            _ = try await missingDrop.list("kea/v1/")
        } catch let err as SyncError {
            if case .missing = err { threwMissing = true }
        }
        try require(threwMissing, "FolderDrop on missing root should throw .missing")
        print("PASS: FolderDrop")

        // 2. SyncSeal
        let salt = Data("0123456789abcdef".utf8)
        let key1 = SyncSeal.key(passphrase: "correct horse", salt: salt)
        let key2 = SyncSeal.key(passphrase: "correct horse", salt: salt)
        let wrongKey = SyncSeal.key(passphrase: "wrong battery", salt: salt)
        let k1Bytes = key1.withUnsafeBytes { Data($0) }
        let k2Bytes = key2.withUnsafeBytes { Data($0) }
        try require(
            k1Bytes == k2Bytes && k1Bytes.count == 32,
            "same passphrase and salt give equal 32-byte keys")

        let secretText = Data("super-secret-bookmark-payload-12345".utf8)
        let sealed = try SyncSeal.seal(secretText, with: key1)
        try require(sealed.range(of: secretText) == nil, "sealed bytes must not contain plaintext")
        let opened = try SyncSeal.open(sealed, with: key2)
        try require(opened == secretText, "open(seal(x)) equals x")

        var threwDamaged = false
        do {
            _ = try SyncSeal.open(sealed, with: wrongKey)
        } catch SyncError.damaged {
            threwDamaged = true
        }
        try require(threwDamaged, "wrong key throws SyncError.damaged")
        print("PASS: SyncSeal")

        // 3. SigV4, the AWS GET Object vector
        let iso = ISO8601DateFormatter()
        let awsDate = iso.date(from: "2013-05-24T00:00:00Z")!
        let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let auth = SigV4.authorization(
            method: "GET",
            url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
            headers: [
                "host": "examplebucket.s3.amazonaws.com",
                "range": "bytes=0-9",
                "x-amz-content-sha256": emptyHash,
                "x-amz-date": "20130524T000000Z",
            ],
            payloadHash: emptyHash,
            access: "AKIAIOSFODNN7EXAMPLE",
            secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            region: "us-east-1",
            date: awsDate
        )
        let expectedAuth =
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        try require(auth == expectedAuth, "SigV4 mismatch: got \(auth)")
        print("PASS: SigV4")

        // 4. BucketDrop.listing
        let sampleXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListBucketResult xmlns="http://doc.s3.amazonaws.com/2006-03-01">
                <Name>kea-bucket</Name>
                <NextContinuationToken>abc</NextContinuationToken>
                <Contents>
                    <Key>kea/v1/devices/1/bookmarks.kea</Key>
                    <LastModified>2025-05-01T12:34:56.789Z</LastModified>
                </Contents>
                <Contents>
                    <Key>kea/v1/devices/2/tabs.kea</Key>
                    <LastModified>2025-05-01T12:35:00Z</LastModified>
                </Contents>
            </ListBucketResult>
            """.data(using: .utf8)!
        let parsed = BucketDrop.listing(sampleXML)
        try require(parsed.names.count == 2, "expected 2 Contents items")
        try require(parsed.names["kea/v1/devices/1/bookmarks.kea"] != nil, "expected first key")
        try require(parsed.names["kea/v1/devices/2/tabs.kea"] != nil, "expected second key")
        try require(parsed.next == "abc", "expected NextContinuationToken abc")
        print("PASS: BucketDrop.listing")

        // 5. BucketDrop.allowed
        try require(
            BucketDrop.allowed(URL(string: "https://storage.googleapis.com")!) == true,
            "https allowed")
        try require(
            BucketDrop.allowed(URL(string: "http://127.0.0.1:9000")!) == true,
            "localhost http allowed")
        try require(
            BucketDrop.allowed(URL(string: "http://example.com")!) == false, "remote http rejected")
        print("PASS: BucketDrop.allowed")

        // 6. SyncMerge
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let t1 = t0.addingTimeInterval(10)
        let t2 = t0.addingTimeInterval(20)
        let t3 = t0.addingTimeInterval(30)

        // (a) stamp
        var ledger = SyncLedger()
        let d1 = Data("one".utf8)
        let d2 = Data("two".utf8)
        let d2Changed = Data("two-v2".utf8)
        SyncMerge.stamp(["a": d1, "b": d2], into: &ledger, now: t1)
        try require(
            ledger.marks["a"]?.at == t1 && ledger.marks["b"]?.at == t1, "initial stamp sets t1")
        SyncMerge.stamp(["a": d1, "b": d2Changed], into: &ledger, now: t2)
        try require(ledger.marks["a"]?.at == t1, "unchanged key keeps t1")
        try require(ledger.marks["b"]?.at == t2, "changed key moves to t2")
        SyncMerge.stamp(["a": d1], into: &ledger, now: t3)
        try require(ledger.marks["b"] == nil && ledger.gone["b"] == t3, "removed key moves to gone")

        // (b) take: newer, older, tie equal hash, tie different hash
        var takeLedger = SyncLedger(marks: [
            "k": SyncMark(hash: SyncMerge.hash(d1), at: t2)
        ])
        let olderDoc = SyncDoc(records: ["k": SyncRecord(data: d2, at: t1)])
        try require(
            SyncMerge.take(olderDoc, against: takeLedger).put.isEmpty, "older remote is not put")

        let newerDoc = SyncDoc(records: ["k": SyncRecord(data: d2, at: t3)])
        try require(
            SyncMerge.take(newerDoc, against: takeLedger).put["k"] != nil, "newer remote is put")

        let tieSameDoc = SyncDoc(records: ["k": SyncRecord(data: d1, at: t2)])
        try require(
            SyncMerge.take(tieSameDoc, against: takeLedger).put.isEmpty,
            "tie with equal hash is not put")

        let h1 = SyncMerge.hash(d1)
        let h2 = SyncMerge.hash(d2)
        let highData = h1 > h2 ? d1 : d2
        let lowData = h1 > h2 ? d2 : d1
        takeLedger.marks["k"] = SyncMark(hash: SyncMerge.hash(lowData), at: t2)
        let tieHigherDoc = SyncDoc(records: ["k": SyncRecord(data: highData, at: t2)])
        try require(
            SyncMerge.take(tieHigherDoc, against: takeLedger).put["k"] != nil,
            "tie with greater hash is put")
        takeLedger.marks["k"] = SyncMark(hash: SyncMerge.hash(highData), at: t2)
        let tieLowerDoc = SyncDoc(records: ["k": SyncRecord(data: lowData, at: t2)])
        try require(
            SyncMerge.take(tieLowerDoc, against: takeLedger).put.isEmpty,
            "tie with smaller hash is not put")

        // (c) Removal: remote tombstone newer vs older
        let remNewer = SyncDoc(gone: ["k": t3])
        try require(
            SyncMerge.take(remNewer, against: takeLedger).remove["k"] == t3,
            "newer tombstone removes")
        let remOlder = SyncDoc(gone: ["k": t1])
        try require(
            SyncMerge.take(remOlder, against: takeLedger).remove.isEmpty,
            "older tombstone does not remove")

        // (d) settle
        var settleLedger = SyncLedger()
        let remRec = SyncRecord(data: d1, at: t1)
        SyncMerge.settle("k", local: d1, remote: remRec, in: &settleLedger, now: t2)
        try require(settleLedger.marks["k"]?.at == t1, "settle equal gives remote.at")
        SyncMerge.settle("k", local: d2, remote: remRec, in: &settleLedger, now: t2)
        try require(settleLedger.marks["k"]?.at == t2, "settle merged gives now")

        // (e) doc drops tombstones older than 90 days
        let oldGoneDate = t3.addingTimeInterval(-91 * 86_400)
        let freshGoneDate = t3.addingTimeInterval(-10 * 86_400)
        let docLedger = SyncLedger(
            marks: ["a": SyncMark(hash: SyncMerge.hash(d1), at: t1)],
            gone: ["old": oldGoneDate, "fresh": freshGoneDate]
        )
        let builtDoc = SyncMerge.doc(["a": d1], ledger: docLedger, now: t3)
        try require(
            builtDoc.gone["old"] == nil && builtDoc.gone["fresh"] == freshGoneDate,
            "doc drops >90d tombstones")

        // (f) Convergence
        var ledgerA = SyncLedger()
        var ledgerB = SyncLedger()
        var storeA = ["x": d1]
        var storeB = ["x": d2]
        SyncMerge.stamp(storeA, into: &ledgerA, now: t1)
        SyncMerge.stamp(storeB, into: &ledgerB, now: t2)
        let docA = SyncMerge.doc(storeA, ledger: ledgerA, now: t1)
        let docB = SyncMerge.doc(storeB, ledger: ledgerB, now: t2)

        let takeOnA = SyncMerge.take(docB, against: ledgerA)
        for (k, r) in takeOnA.put {
            storeA[k] = r.data
            SyncMerge.settle(k, local: storeA[k], remote: r, in: &ledgerA, now: t3)
        }
        let takeOnB = SyncMerge.take(docA, against: ledgerB)
        for (k, r) in takeOnB.put {
            storeB[k] = r.data
            SyncMerge.settle(k, local: storeB[k], remote: r, in: &ledgerB, now: t3)
        }
        try require(
            storeA["x"] == d2 && storeB["x"] == d2, "both A and B converge on B's newer value")
        print("PASS: SyncMerge")
    }
}
