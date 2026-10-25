import Foundation
import Darwin

public enum ResolverFile {
    public static let path = "/etc/resolver/test"
    public static let content = "# Managed by Docker Domains\nnameserver 127.0.0.1\nport 53535\n"

    public enum State: Equatable, Sendable {
        case missing
        case installed
        case conflict
    }

    public static func state(at path: String = path, owner: uid_t = 0) throws -> State {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return .missing }
            throw DomainError("Could not inspect the .test resolver: \(String(cString: strerror(errno))).")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner else { return .conflict }
        return (try String(contentsOfFile: path, encoding: .utf8)) == content ? .installed : .conflict
    }

    /// Exclusive creation also rejects symlinks, protecting a resolver installed by
    /// another tool, including if the destination changes during authentication.
    public static var authorizationArguments: [String] {
        ["-w", "-c", "-x", "-m", "644", path]
    }
}
