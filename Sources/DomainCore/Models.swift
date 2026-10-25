import Foundation

public struct DomainError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum DomainName {
    public static func normalize(_ input: String) throws -> String {
        let domain = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard domain.utf8.count <= 253, labels.count >= 2, labels.last == "test",
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                  && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else {
            throw DomainError("Use a local domain ending in .test, such as bbq.test.")
        }
        return domain
    }
}

public struct Container: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let running: Bool
    public let project: String?
    public let service: String?
    public let ports: [Int]
    public let networks: Set<String>
    public let networkMode: String
    public var preferredPort: Int { [80, 3000, 8080, 8000, 5173, 4000, 5000, 443].first(where: ports.contains) ?? ports.first ?? 80 }
    public var title: String { project.map { "\($0) / \(service ?? name)" } ?? name }
    public init(id: String, name: String, image: String, running: Bool, project: String?, service: String?, ports: [Int], networks: Set<String> = [], networkMode: String = "default") {
        self.id = id; self.name = name; self.image = image; self.running = running
        self.project = project; self.service = service; self.ports = ports
        self.networks = networks; self.networkMode = networkMode
    }
}

public struct DomainMapping: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var domain: String
    public var containerName: String
    public var project: String?
    public var service: String?
    public var port: Int
    public var upstreamTLS: Bool
    public var enabled: Bool
    public init(id: UUID = UUID(), domain: String, containerName: String, project: String? = nil, service: String? = nil, port: Int, upstreamTLS: Bool = false, enabled: Bool = true) {
        self.id = id; self.domain = domain; self.containerName = containerName
        self.project = project; self.service = service; self.port = port
        self.upstreamTLS = upstreamTLS; self.enabled = enabled
    }
    public init(domain: String, container: Container, port: Int) {
        self.init(domain: domain, containerName: container.name, project: container.project, service: container.service, port: port)
    }
    public func resolve(in containers: [Container]) -> Container? {
        if let exact = containers.first(where: { $0.name == containerName }) { return exact }
        guard let project, let service else { return nil }
        // A replica is never chosen arbitrarily: the user must select a concrete container.
        let matches = containers.filter { $0.project == project && $0.service == service }
        return matches.count == 1 ? matches.first : nil
    }
    public func validated() throws -> Self {
        var result = self
        result.domain = try DomainName.normalize(domain)
        guard (1...65535).contains(port) else { throw DomainError("Choose a container port between 1 and 65535.") }
        return result
    }
}

public enum ProxyConfiguration {
    public static let ownerLabel = "dev.dockerdomains.managed"
    public static let network = "docker-domains"
    public static let container = "docker-domains-proxy"
    public static let image = "caddy:2.10.2-alpine"
    public static func alias(for container: Container) -> String { "dd-" + String(container.id.prefix(12)) }

    public static func render(mappings: [DomainMapping], containers: [Container]) throws -> String {
        var seen = Set<String>()
        var routes: [String] = []
        for raw in mappings where raw.enabled {
            let mapping = try raw.validated()
            guard seen.insert(mapping.domain).inserted else { throw DomainError("\(mapping.domain) is already mapped.") }
            guard let container = mapping.resolve(in: containers), container.running else { continue }
            guard container.networkMode != "host", container.networkMode != "none", !container.networkMode.hasPrefix("container:") else {
                throw DomainError("\(container.name) uses \(container.networkMode) networking. Use a bridge network for domain routing.")
            }
            let scheme = mapping.upstreamTLS ? "https" : "http"
            routes.append("""
                @route\(routes.count) host \(mapping.domain)
                handle @route\(routes.count) {
                    reverse_proxy \(scheme)://\(alias(for: container)):\(mapping.port) {
                        stream_close_delay 5m
                    }
                }
            """)
        }
        return """
        {
            auto_https off
            admin localhost:2019
        }
        :80 {
        \(routes.joined(separator: "\n"))
            handle {
                respond "No running container is mapped to this domain. Open Docker Domains to check the mapping." 404
            }
        }

        """
    }
}
