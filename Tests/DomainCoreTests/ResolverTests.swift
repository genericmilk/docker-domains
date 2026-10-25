import XCTest
import Darwin
@testable import DomainCore

@MainActor
final class ResolverTests: XCTestCase {
    func testResolverOwnershipAndContentChecks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test")
        XCTAssertEqual(try ResolverFile.state(at: file.path, owner: getuid()), .missing)
        try ResolverFile.content.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ResolverFile.state(at: file.path, owner: getuid()), .installed)
        XCTAssertEqual(try ResolverFile.state(at: file.path, owner: getuid() + 1), .conflict)
        try "nameserver 8.8.8.8\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ResolverFile.state(at: file.path, owner: getuid()), .conflict)
        let link = directory.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(try ResolverFile.state(at: link.path, owner: getuid()), .conflict)
        XCTAssertEqual(try ResolverFile.state(at: directory.path, owner: getuid()), .conflict)
    }

    func testNativeAuthorizationUsesExclusiveFixedDestination() {
        let arguments = ResolverFile.authorizationArguments
        XCTAssertEqual(arguments, ["-w", "-c", "-x", "-m", "644", "/etc/resolver/test"])
    }

    func testCommandDeliversInputWithoutShellExpansion() async throws {
        let text = "# Managed by Docker Domains\n$(do-not-expand) `literal` \"quoted\"\n"
        let result = try await Command.run("/bin/cat", [], input: Data(text.utf8))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, text.trimmingCharacters(in: .whitespacesAndNewlines))
        let large = String(repeating: "abc123", count: 100_000)
        let largeResult = try await Command.run("/bin/cat", [], input: Data(large.utf8))
        XCTAssertEqual(largeResult.status, 0)
        XCTAssertEqual(largeResult.output, large)
    }
}
