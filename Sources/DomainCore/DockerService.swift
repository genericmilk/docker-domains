import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let output: String
    public let status: Int32
}

private final class ProcessBox: @unchecked Sendable {
    let process = Process()
}

public enum Command {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30, input: Data? = nil) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            let box = ProcessBox()
            let process = box.process
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            // A private input file avoids pipe deadlocks while an authorization tool
            // waits for the user, and never places its payload in shell arguments.
            var inputDirectory: URL?
            var inputHandle: FileHandle?
            defer {
                try? inputHandle?.close()
                if let inputDirectory { try? FileManager.default.removeItem(at: inputDirectory) }
            }
            if let input {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DockerDomains-input-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                inputDirectory = directory
                let file = directory.appendingPathComponent("input")
                try input.write(to: file, options: .atomic)
                inputHandle = try FileHandle(forReadingFrom: file)
                process.standardInput = inputHandle
            } else {
                process.standardInput = FileHandle.nullDevice
            }
            try process.run()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if box.process.isRunning {
                    box.process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
                    }
                }
            }
            timer.resume()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            return CommandResult(output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), status: process.terminationStatus)
        }.value
    }
}

public actor DockerService {
    private var executable: String?
    private var context: String?
    private var lastConfiguration: String?
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    private func cli(_ arguments: [String], timeout: TimeInterval = 30, allowFailure: Bool = false) async throws -> String {
        guard let executable else { throw DomainError("Docker was not found. Install or open Docker Desktop or OrbStack, then refresh.") }
        let prefix = context.map { ["--context", $0] } ?? []
        let result = try await Command.run(executable, prefix + arguments, timeout: timeout)
        guard allowFailure || result.status == 0 else {
            let output = String(result.output.suffix(1600))
            throw DomainError(output.isEmpty ? "Docker did not finish the operation. Check that your container engine is running." : output)
        }
        return result.output
    }

    public func connect() async throws -> String {
        if let context { return context }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [home + "/.docker/bin/docker", "/usr/local/bin/docker", "/opt/homebrew/bin/docker", home + "/.orbstack/bin/docker"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/docker" }
        executable = paths.first { FileManager.default.isExecutableFile(atPath: $0) }
        let name = try await cli(["context", "show"])
        let endpoint = try await cli(["context", "inspect", name, "--format", "{{.Endpoints.docker.Host}}"])
        guard endpoint.hasPrefix("unix://") else { throw DomainError("Choose a local Docker context. Remote engines cannot serve domains on this Mac.") }
        context = name
        return name
    }

    public func containers() async throws -> [Container] {
        _ = try await connect()
        let ids = try await cli(["ps", "-aq"])
            .split(whereSeparator: \.isNewline).map(String.init)
        guard !ids.isEmpty else { return [] }
        let format = #"{"id":{{json .Id}},"name":{{json .Name}},"image":{{json .Config.Image}},"running":{{json .State.Running}},"labels":{{json (index .Config "Labels")}},"exposed":{{json (index .Config "ExposedPorts")}},"bindings":{{json (index .HostConfig "PortBindings")}},"networks":{{json .NetworkSettings.Networks}},"mode":{{json .HostConfig.NetworkMode}}}"#
        let output = try await cli(["inspect", "--format", format] + ids)
        return try output.split(whereSeparator: \.isNewline).compactMap { line -> Container? in
            let value = try JSONDecoder().decode(Inspection.self, from: Data(line.utf8))
            guard value.labels?[ProxyConfiguration.ownerLabel] != "true" else { return nil }
            let keys = Set((value.exposed ?? [:]).keys).union((value.bindings ?? [:]).keys)
            let ports = keys.filter { $0.hasSuffix("/tcp") }.compactMap { Int($0.split(separator: "/")[0]) }.sorted()
            return Container(id: value.id, name: String(value.name.drop(while: { $0 == "/" })), image: value.image,
                             running: value.running, project: value.labels?["com.docker.compose.project"],
                             service: value.labels?["com.docker.compose.service"], ports: ports,
                             networks: Set((value.networks ?? [:]).keys), networkMode: value.mode)
        }.sorted { ($0.project ?? $0.name, $0.name) < ($1.project ?? $1.name, $1.name) }
    }

    public func start(_ container: Container) async throws {
        _ = try await cli(["start", container.id], timeout: 90)
    }

    public func proxyRunning() async -> Bool {
        guard context != nil else { return false }
        return (try? await cli(["inspect", "--format", "{{.State.Running}} {{index .Config.Labels \"\(ProxyConfiguration.ownerLabel)\"}}", ProxyConfiguration.container])) == "true true"
    }

    public func synchronize(_ mappings: [DomainMapping], containers: [Container]) async throws {
        let config = try ProxyConfiguration.render(mappings: mappings, containers: containers)
        let hasMappings = mappings.contains(where: \.enabled)
        guard hasMappings else {
            if try await ownedProxyExists() { _ = try await cli(["stop", ProxyConfiguration.container]) }
            lastConfiguration = nil
            return
        }
        let networkExists = try await cli(["network", "ls", "--filter", "name=^\(ProxyConfiguration.network)$", "--format", "{{.Name}}"])
        if networkExists.isEmpty {
            _ = try await cli(["network", "create", "--label", "\(ProxyConfiguration.ownerLabel)=true", ProxyConfiguration.network])
        } else {
            let owner = try await cli(["network", "inspect", "--format", "{{index .Labels \"\(ProxyConfiguration.ownerLabel)\"}}", ProxyConfiguration.network])
            guard owner == "true" else { throw DomainError("A network named docker-domains already exists and belongs to another app.") }
        }
        var connected = Set<String>()
        for mapping in mappings where mapping.enabled {
            guard let container = mapping.resolve(in: containers), container.running,
                  connected.insert(container.id).inserted else { continue }
            if !container.networks.contains(ProxyConfiguration.network) {
                _ = try await cli(["network", "connect", "--alias", ProxyConfiguration.alias(for: container),
                                   "--gw-priority", "-1", ProxyConfiguration.network, container.id])
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Caddyfile")
        let old = try? String(contentsOf: file, encoding: .utf8)
        try config.write(to: file, atomically: true, encoding: .utf8)
        do {
            if try await ownedProxyExists() {
                if !(await proxyRunning()) {
                    _ = try await cli(["start", ProxyConfiguration.container])
                    lastConfiguration = nil
                }
                if lastConfiguration != config {
                    _ = try await cli(["exec", ProxyConfiguration.container, "caddy", "reload", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"])
                }
            } else {
                _ = try await cli(["run", "-d", "--name", ProxyConfiguration.container,
                                   "--label", "\(ProxyConfiguration.ownerLabel)=true", "--restart", "unless-stopped",
                                   "--network", ProxyConfiguration.network, "-p", "127.0.0.1:80:80",
                                   "--mount", "type=bind,source=\(directory.path),target=/etc/caddy,readonly",
                                   "--cap-drop", "ALL", "--cap-add", "NET_BIND_SERVICE",
                                   "--security-opt", "no-new-privileges:true", ProxyConfiguration.image], timeout: 180)
                // Check actual process state as a detached docker run can succeed before Caddy exits.
                _ = try await cli(["exec", ProxyConfiguration.container, "caddy", "validate", "--config", "/etc/caddy/Caddyfile"])
            }
            lastConfiguration = config
        } catch {
            if let old { try? old.write(to: file, atomically: true, encoding: .utf8) }
            lastConfiguration = nil
            throw DomainError("Could not apply domain routes. Port 80 must be available.\n\(error.localizedDescription)")
        }
    }

    private func ownedProxyExists() async throws -> Bool {
        let name = try await cli(["ps", "-a", "--filter", "name=^/\(ProxyConfiguration.container)$", "--format", "{{.Names}}"])
        guard !name.isEmpty else { return false }
        let owner = try await cli(["inspect", "--format", "{{index .Config.Labels \"\(ProxyConfiguration.ownerLabel)\"}}", ProxyConfiguration.container])
        guard owner == "true" else { throw DomainError("A container named docker-domains-proxy already exists and belongs to another app.") }
        return true
    }

    public func removeInfrastructure() async throws {
        if try await ownedProxyExists() { _ = try await cli(["rm", "-f", ProxyConfiguration.container]) }
        let owner = try? await cli(["network", "inspect", "--format", "{{index .Labels \"\(ProxyConfiguration.ownerLabel)\"}}", ProxyConfiguration.network])
        if owner == "true" {
            let ids = try await cli(["network", "inspect", "--format", "{{range $id, $container := .Containers}}{{$id}} {{end}}", ProxyConfiguration.network])
            for id in ids.split(separator: " ") {
                _ = try await cli(["network", "disconnect", ProxyConfiguration.network, String(id)])
            }
            _ = try await cli(["network", "rm", ProxyConfiguration.network])
        }
        lastConfiguration = nil
    }
}

private struct IgnoredJSON: Decodable {
    init(from decoder: Decoder) throws {}
}
private struct Inspection: Decodable {
    let id: String
    let name: String
    let image: String
    let running: Bool
    let labels: [String: String]?
    let exposed: [String: IgnoredJSON]?
    let bindings: [String: IgnoredJSON?]?
    let networks: [String: IgnoredJSON]?
    let mode: String
}
