import AppKit
import SwiftUI
import ServiceManagement
import DomainCore

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()
    @Published var mappings: [DomainMapping] = []
    @Published var containers: [Container] = []
    @Published var context = "Connecting"
    @Published var dockerAvailable = false
    @Published var dnsReady = false
    @Published var resolverInstalled = Resolver.installed
    @Published var proxyReady = false
    @Published var busy = false
    @Published var error: String?
    @Published var search = ""
    @Published var editor: MappingDraft?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var routingEnabled: Bool
    private var poller: Task<Void, Never>?
    private let dns = LocalDNS()
    let docker: DockerService
    let directory: URL
    private let mappingsFile: URL

    var ready: Bool { dockerAvailable && dnsReady && resolverInstalled && proxyReady && routingEnabled }
    var visibleMappings: [DomainMapping] {
        mappings.filter { search.isEmpty || $0.domain.localizedCaseInsensitiveContains(search) || $0.containerName.localizedCaseInsensitiveContains(search) }
            .sorted { $0.domain < $1.domain }
    }
    var activeCount: Int { mappings.filter { $0.enabled && $0.resolve(in: containers)?.running == true }.count }
    var status: String {
        if !routingEnabled { return "Routing paused" }
        if !dockerAvailable { return "Waiting for Docker" }
        if !dnsReady { return "Local DNS unavailable" }
        if !resolverInstalled { return "Set up local domains" }
        if !proxyReady && mappings.contains(where: \.enabled) { return "Proxy unavailable" }
        return "\(activeCount) \(activeCount == 1 ? "domain" : "domains") ready"
    }

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Docker Domains")
        mappingsFile = directory.appendingPathComponent("mappings.json")
        docker = DockerService(directory: directory.appendingPathComponent("proxy"))
        routingEnabled = !UserDefaults.standard.bool(forKey: "routingPaused")
        do {
            if FileManager.default.fileExists(atPath: mappingsFile.path) {
                mappings = try JSONDecoder().decode([DomainMapping].self, from: Data(contentsOf: mappingsFile))
                var seen = Set<String>()
                for mapping in mappings {
                    let validated = try mapping.validated()
                    guard seen.insert(validated.domain).inserted else { throw DomainError("Duplicate domain in saved mappings: \(validated.domain)") }
                }
            }
        } catch { self.error = "Could not read saved domains. The file was left unchanged. \(error.localizedDescription)" }
    }

    func boot() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            guard let self else { return }
            do { try await dns.start(); dnsReady = true } catch { self.error = error.localizedDescription }
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                await refresh()
            }
        }
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        resolverInstalled = Resolver.installed
        do {
            context = try await docker.connect()
            let found = try await docker.containers()
            containers = found
            dockerAvailable = true
        } catch {
            dockerAvailable = false; proxyReady = false
            self.error = error.localizedDescription
            return
        }
        do {
            if routingEnabled { try await docker.synchronize(mappings, containers: containers) }
            proxyReady = await docker.proxyRunning()
        } catch { proxyReady = false; self.error = error.localizedDescription }
    }

    func save(_ draft: MappingDraft) async {
        do {
            guard let container = containers.first(where: { $0.id == draft.containerID }) else { throw DomainError("Choose a container.") }
            guard let port = Int(draft.port) else { throw DomainError("Enter a container port.") }
            var mapping = DomainMapping(domain: draft.domain, container: container, port: port)
            mapping.id = draft.id
            mapping.upstreamTLS = draft.upstreamTLS
            mapping.enabled = draft.enabled
            mapping = try mapping.validated()
            guard !mappings.contains(where: { $0.id != mapping.id && $0.domain == mapping.domain }) else { throw DomainError("\(mapping.domain) already has a mapping.") }
            var updated = mappings
            if let index = updated.firstIndex(where: { $0.id == mapping.id }) { updated[index] = mapping } else { updated.append(mapping) }
            try persist(updated)
            editor = nil
            error = nil
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func persist(_ updated: [DomainMapping]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: mappingsFile, options: .atomic)
        mappings = updated
    }

    func toggle(_ mapping: DomainMapping) async {
        var updated = mappings
        guard let index = updated.firstIndex(where: { $0.id == mapping.id }) else { return }
        updated[index].enabled.toggle()
        do { try persist(updated); await refresh() } catch { self.error = error.localizedDescription }
    }

    func remove(_ mapping: DomainMapping) async {
        do { try persist(mappings.filter { $0.id != mapping.id }); await refresh() } catch { self.error = error.localizedDescription }
    }

    func setUpDNS() async {
        guard !busy else { return }
        busy = true
        do {
            if !dnsReady { try await dns.start(); dnsReady = true }
            try await Resolver.install()
            resolverInstalled = Resolver.installed
            error = nil
        } catch { self.error = error.localizedDescription }
        busy = false
        await refresh()
    }

    func start(_ container: Container) async {
        guard !busy else { return }; busy = true
        do { try await docker.start(container); error = nil } catch { self.error = error.localizedDescription }
        busy = false; await refresh()
    }

    func pauseOrResume() async {
        guard !busy else { return }; busy = true
        do {
            try await docker.synchronize(routingEnabled ? [] : mappings, containers: containers)
            routingEnabled.toggle()
            UserDefaults.standard.set(!routingEnabled, forKey: "routingPaused")
            error = nil
        } catch { self.error = error.localizedDescription }
        busy = false; await refresh()
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
        } catch { self.error = error.localizedDescription }
    }

    func uninstall() async {
        guard !busy else { return }; busy = true
        do {
            // Remove DNS first: a cancelled password prompt leaves routing intact.
            if Resolver.installed { try await Resolver.remove() }
            resolverInstalled = Resolver.installed
            try await docker.removeInfrastructure()
            routingEnabled = false
            UserDefaults.standard.set(true, forKey: "routingPaused")
            proxyReady = false; error = nil
        } catch { self.error = error.localizedDescription }
        busy = false
    }

    func open(_ mapping: DomainMapping) { NSWorkspace.shared.open(URL(string: "http://\(mapping.domain)")!) }
    func copy(_ mapping: DomainMapping) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://\(mapping.domain)", forType: .string)
    }
    func newMapping(container: Container? = nil) {
        var draft = MappingDraft()
        if let container {
            draft.containerID = container.id; draft.port = String(container.preferredPort)
            let suggestion = (container.project ?? container.name).lowercased().replacingOccurrences(of: "_", with: "-")
            draft.domain = suggestion + ".test"
        }
        editor = draft
    }
    func edit(_ mapping: DomainMapping) { editor = MappingDraft(mapping, containers: containers) }
}

struct MappingDraft: Identifiable {
    var id = UUID()
    var domain = ""
    var containerID = ""
    var port = "80"
    var upstreamTLS = false
    var enabled = true
    init() {}
    init(_ mapping: DomainMapping, containers: [Container]) {
        id = mapping.id; domain = mapping.domain; port = String(mapping.port)
        containerID = mapping.resolve(in: containers)?.id ?? ""
        upstreamTLS = mapping.upstreamTLS; enabled = mapping.enabled
    }
}
