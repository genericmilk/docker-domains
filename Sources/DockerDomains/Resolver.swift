import AppKit
import Darwin
import DomainCore

enum Resolver {
    static let path = ResolverFile.path
    static let content = ResolverFile.content
    static var installed: Bool { (try? ResolverFile.state()) == .installed }

    @MainActor
    static func install() async throws {
        switch try ResolverFile.state() {
        case .installed: return
        case .conflict:
            throw DomainError("Another .test resolver is already installed. It was left unchanged.")
        case .missing: break
        }

        // authopen can create files, but not their parent directories. Macs without
        // /etc/resolver need this directory bootstrap once; do not change PAM or sudo.
        var directory = ObjCBool(false)
        if !FileManager.default.fileExists(atPath: "/etc/resolver", isDirectory: &directory) {
            try await privileged("/bin/mkdir -m 755 /etc/resolver", prompt: "Docker Domains needs to create the local DNS configuration folder.")
        } else if !directory.boolValue {
            throw DomainError("/etc/resolver is not a directory. It was left unchanged.")
        }
        var directoryInfo = stat()
        guard lstat("/etc/resolver", &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == 0, directoryInfo.st_mode & 0o022 == 0 else {
            throw DomainError("The local DNS folder must be a protected, root-owned directory. It was left unchanged.")
        }

        NSApp.activate(ignoringOtherApps: true)
        let result = try await Command.run("/usr/libexec/authopen", ResolverFile.authorizationArguments,
                                           timeout: 180, input: Data(content.utf8))
        guard result.status == 0 else {
            if result.output.contains("-60006") || result.output.localizedCaseInsensitiveContains("cancel") {
                throw DomainError("Setup was cancelled. Local domains have not been configured.")
            }
            throw DomainError(result.output.isEmpty ? "macOS did not authorize local domain setup." : result.output)
        }
        guard installed else { throw DomainError("macOS could not finish writing the .test resolver. Try setup again.") }

        // macOS watches /etc/resolver. Flushing the user's cache needs no root shell.
        _ = try? await Command.run("/usr/bin/dscacheutil", ["-flushcache"])
    }

    static func remove() async throws {
        let script = """
        set -eu
        expected='\(content.trimmingCharacters(in: .newlines))'
        if [ -L /etc/resolver/test ]; then exit 1; fi
        if [ -f /etc/resolver/test ] && [ "$(/bin/cat /etc/resolver/test)" = "$expected" ]; then
          /bin/rm /etc/resolver/test
          /usr/bin/dscacheutil -flushcache
          /usr/bin/killall -HUP mDNSResponder || true
        fi
        """
        try await privileged(script, prompt: "Docker Domains needs to remove its local DNS configuration.")
    }

    private static func privileged(_ script: String, prompt: String) async throws {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        let result = try await Command.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""], timeout: 180)
        guard result.status == 0 else {
            if result.output.contains("-128") { throw DomainError("The operation was cancelled.") }
            throw DomainError(result.output)
        }
    }
}
