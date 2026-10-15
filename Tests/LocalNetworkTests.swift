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
private struct LocalNetworkTests {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let accepted = [
            "http://127.0.0.1:8080/v1",
            "http://localhost:11434/v1/",
            "http://[::1]:8080/v1/",
            "http://10.1.2.3/v1/",
            "http://172.16.0.1/",
            "http://172.31.255.255/",
            "http://192.168.1.20:8000/v1/",
            "http://169.254.10.10/",
            "http://mybox.local:8080/v1/",
            "https://nas.home.arpa/v1/",
        ]
        for input in accepted {
            guard let url = LocalNetwork.server(from: input) else {
                throw TestFailure.check("expected accepted: \(input)")
            }
            try require(url.absoluteString.hasSuffix("/"), "expected trailing slash on \(url.absoluteString)")
        }
        try require(LocalNetwork.server(from: "http://127.0.0.1:8080/v1")?.absoluteString == "http://127.0.0.1:8080/v1/",
                    "expected trailing slash added")

        let rejected = [
            "http://172.32.0.1/v1/",
            "https://8.8.8.8/v1/",
            "http://example.com/v1/",
            "http://box.local.example.com/",
            "http://192.168.1/",
            "http://1.2.3.4.5/",
            "http://u:p@192.168.1.2/",
            "ftp://192.168.1.2/",
            "http://192.168.1.2/v1/?x=1",
            "",
        ]
        for input in rejected {
            try require(LocalNetwork.server(from: input) == nil, "expected rejected: \(input)")
        }

        for host in ["127.0.0.1", "::1", "[::1]", "localhost", "LOCALHOST"] {
            try require(LocalNetwork.onThisMac(host), "expected onThisMac for \(host)")
        }
        for host in ["192.168.1.20", "10.0.0.1", "mybox.local", "nas.home.arpa", "example.com"] {
            try require(!LocalNetwork.onThisMac(host), "expected not onThisMac for \(host)")
        }
        print("PASS local network address validation")
    }
}
