import XCTest

/// No test may reach the real Keychain (#732).
///
/// `swift test` runs an ad-hoc-signed `xctest` binary whose code identity
/// changes on every build and in every worktree, so any Keychain read raises a
/// "xctest wants to use … com.onelo.auth" dialog, "Always Allow" never sticks,
/// and the test hangs until someone answers it.
///
/// The compiler covers half of this: the test-only `OneloAuth` initializers
/// require a `storage:`. This test covers the rest. It reads every test source
/// and fails on any way to the real Keychain: the Keychain-backed store, the
/// Security framework, App Attest's own Keychain helpers, the production store
/// factory, or a public `OneloAuth(config:)` / `Onelo(publishableKey:)` that
/// would build one. Build the SDK with `InMemorySessionStorage` and
/// `Onelo(testingKey:…)` (Support/InMemorySessionStorage.swift) instead.
final class KeychainIsolationGuardTests: XCTestCase {

    private static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private static let exempt: Set<String> = ["KeychainIsolationGuardTests.swift"]

    /// Source text with `//` comments removed, so prose that names a forbidden
    /// call is not mistaken for one.
    private func code(of url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let r = line.range(of: "//") else { return line }
            return line[..<r.lowerBound]
        }.joined(separator: "\n")
    }

    private func testSources() throws -> [URL] {
        let walker = FileManager.default.enumerator(at: Self.testsDirectory, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == "swift", !Self.exempt.contains(url.lastPathComponent) { out.append(url) }
        }
        return out
    }

    /// The argument list of every call to `prefix` (an identifier plus `(`),
    /// matched by balanced parentheses.
    private func calls(_ prefix: String, in code: String) -> [String] {
        var out: [String] = []
        var search = code.startIndex..<code.endIndex
        while let hit = code.range(of: prefix, range: search) {
            // A whole identifier only: `MockOneloAuth(` is not `OneloAuth(`.
            if hit.lowerBound > code.startIndex {
                let before = code[code.index(before: hit.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" {
                    search = hit.upperBound..<code.endIndex
                    continue
                }
            }
            var depth = 1
            var i = hit.upperBound
            while i < code.endIndex, depth > 0 {
                if code[i] == "(" { depth += 1 } else if code[i] == ")" { depth -= 1 }
                i = code.index(after: i)
            }
            out.append(String(code[hit.upperBound..<i]))
            search = i..<code.endIndex
        }
        return out
    }

    /// `token` at the start of an identifier: `SecItemAdd` and
    /// `SecItemKeychainBackend` match, the status constant `errSecItemNotFound`
    /// (no Keychain call) does not (#740).
    private func containsIdentifier(_ token: String, in code: String) -> Bool {
        var search = code.startIndex..<code.endIndex
        while let hit = code.range(of: token, range: search) {
            if hit.lowerBound == code.startIndex { return true }
            let before = code[code.index(before: hit.lowerBound)]
            if !(before.isLetter || before.isNumber || before == "_") { return true }
            search = hit.upperBound..<code.endIndex
        }
        return false
    }

    func test_the_suite_scans_the_test_sources() throws {
        // A guard that found no files would pass while checking nothing.
        let names = try testSources().map(\.lastPathComponent)
        XCTAssertTrue(names.contains("InMemorySessionStorage.swift"))
        XCTAssertGreaterThan(names.count, 20)
    }

    func test_no_test_reaches_the_real_keychain() throws {
        var violations: [String] = []
        for url in try testSources() {
            let source = try code(of: url)
            let file = url.lastPathComponent
            for token in ["KeychainStorage", "SecItem", "kSecClass", "OneloAppAttest(", "OneloSessionStorageFactory"]
            where containsIdentifier(token, in: source) {
                violations.append("\(file): uses \(token)")
            }
            for args in calls("OneloAuth(", in: source) where !args.contains("storage:") {
                violations.append("\(file): OneloAuth(\(args.prefix(60))…) without an in-memory storage:")
            }
            for args in calls("Onelo(", in: source)
            where args.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("publishableKey:") {
                violations.append("\(file): Onelo(publishableKey:) builds a Keychain-backed auth; use Onelo(testingKey:)")
            }
        }
        XCTAssertEqual(violations, [], "Tests must not touch the real Keychain (#732):\n" + violations.joined(separator: "\n"))
    }
}
