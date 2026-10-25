import AppKit
import SwiftUI
import DomainCore

struct DomainMenu: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(store.status)
        Divider()
        ForEach(store.mappings.sorted { $0.domain < $1.domain }) { mapping in
            Button { store.open(mapping) } label: {
                Label(mapping.domain, systemImage: mapping.enabled ? "globe" : "pause.circle")
            }
            .disabled(!store.ready || !mapping.enabled || mapping.resolve(in: store.containers)?.running != true)
        }
        if !store.mappings.isEmpty { Divider() }
        Button("Manage Domains…") { showManager() }.keyboardShortcut("o")
        Button("Add Domain…") {
            showManager()
            store.newMapping()
        }.keyboardShortcut("n").disabled(!store.dockerAvailable || store.busy)
        Divider()
        Button(store.routingEnabled ? "Pause Routing" : "Resume Routing") {
            Task { await store.pauseOrResume() }
        }.disabled(store.busy)
        SettingsLink().keyboardShortcut(",")
        Divider()
        Button("Quit Docker Domains") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func showManager() {
        openWindow(id: "domains")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct DomainsWindow: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection: DomainMapping.ID?
    private var selectedMapping: DomainMapping? { store.visibleMappings.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Domains") {
                    ForEach(store.visibleMappings) { mapping in
                        Label {
                            VStack(alignment: .leading) {
                                Text(mapping.domain)
                                Text(mapping.containerName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: mapping.enabled ? "globe" : "pause.circle")
                        }
                        .tag(mapping.id)
                        .contextMenu { DomainActions(mapping: mapping) }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $store.search, placement: .sidebar, prompt: "Search Domains")
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
            .safeAreaInset(edge: .bottom) {
                LabeledContent("Docker", value: store.context)
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
        } detail: {
            if let mapping = selectedMapping {
                DomainDetail(mapping: mapping)
            } else if !store.search.isEmpty && store.visibleMappings.isEmpty {
                ContentUnavailableView.search(text: store.search)
            } else {
                ContentUnavailableView {
                    Label(store.mappings.isEmpty ? "No Domains" : "Select a Domain", systemImage: "globe")
                } actions: {
                    if store.mappings.isEmpty {
                        Button("Add Domain…") { store.newMapping() }
                            .disabled(!store.dockerAvailable || store.busy)
                    }
                }
            }
        }
        .navigationTitle("Docker Domains")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ControlGroup {
                    Button { store.newMapping() } label: { Label("Add Domain", systemImage: "plus") }
                        .help("Add Domain").keyboardShortcut("n")
                        .disabled(!store.dockerAvailable || store.busy)
                    Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Refresh Containers").disabled(store.busy)
                }.controlGroupStyle(.navigation)
            }
            if let mapping = selectedMapping {
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    ControlGroup {
                        Button { store.open(mapping) } label: { Label("Open in Browser", systemImage: "safari") }
                            .help("Open in Browser")
                            .disabled(!store.ready || !mapping.enabled || mapping.resolve(in: store.containers)?.running != true)
                        Button { store.edit(mapping) } label: { Label("Edit Domain", systemImage: "pencil") }
                            .help("Edit Domain").keyboardShortcut("e")
                        Menu { DomainActions(mapping: mapping) } label: { Label("More", systemImage: "ellipsis.circle") }
                            .menuIndicator(.hidden).help("Domain Actions")
                    }.controlGroupStyle(.navigation)
                }
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Label("Settings", systemImage: "gearshape") }.help("Settings")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { OperationError() }
        .sheet(item: $store.editor) { draft in
            MappingEditor(draft: draft).environmentObject(store)
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: store.mappings.map(\.id)) { _, _ in selectFirstIfNeeded() }
        .onChange(of: store.search) { _, _ in selectFirstIfNeeded() }
        .onDeleteCommand {
            if let mapping = selectedMapping, !store.busy { Task { await store.remove(mapping) } }
        }
        .frame(minWidth: 680, minHeight: 440)
    }

    private func selectFirstIfNeeded() {
        if selectedMapping == nil { selection = store.visibleMappings.first?.id }
    }
}

private struct DomainDetail: View {
    @EnvironmentObject private var store: AppStore
    let mapping: DomainMapping
    private var container: Container? { mapping.resolve(in: store.containers) }

    var body: some View {
        Form {
            Section("Domain") {
                LabeledContent("Address") { Text("http://\(mapping.domain)").textSelection(.enabled) }
                Toggle("Enabled", isOn: Binding(
                    get: { mapping.enabled },
                    set: { _ in Task { await store.toggle(mapping) } }
                )).disabled(store.busy)
            }
            Section("Container") {
                LabeledContent("Name", value: container?.name ?? mapping.containerName)
                LabeledContent("Port", value: String(mapping.port))
                LabeledContent("Protocol", value: mapping.upstreamTLS ? "HTTPS" : "HTTP")
                LabeledContent("Status") {
                    if let container {
                        HStack {
                            Text(container.running ? "Running" : "Stopped").foregroundStyle(.secondary)
                            if !container.running {
                                Button("Start") { Task { await store.start(container) } }.disabled(store.busy)
                            }
                        }
                    } else { Text("Not Found").foregroundStyle(.secondary) }
                }
            }
            Section("Local Routing") {
                LabeledContent("Status", value: store.status)
                if !store.resolverInstalled {
                    LabeledContent("Local DNS") {
                        Button("Set Up…") { Task { await store.setUpDNS() } }.disabled(store.busy)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mapping.domain)
    }
}

private struct DomainActions: View {
    @EnvironmentObject private var store: AppStore
    let mapping: DomainMapping
    var body: some View {
        Button("Open in Browser") { store.open(mapping) }
            .disabled(!store.ready || !mapping.enabled || mapping.resolve(in: store.containers)?.running != true)
        Button("Copy URL") { store.copy(mapping) }
        Button("Edit Domain…") { store.edit(mapping) }
        Divider()
        Button(mapping.enabled ? "Disable Domain" : "Enable Domain") { Task { await store.toggle(mapping) } }.disabled(store.busy)
        Button("Remove Domain", role: .destructive) { Task { await store.remove(mapping) } }.disabled(store.busy)
    }
}

private struct MappingEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: MappingDraft
    @FocusState private var domainFocused: Bool
    private var isEditing: Bool { store.mappings.contains { $0.id == draft.id } }
    private var validation: String? {
        guard !draft.domain.isEmpty else { return nil }
        do { _ = try DomainName.normalize(draft.domain) } catch { return error.localizedDescription }
        if store.mappings.contains(where: { $0.id != draft.id && $0.domain == draft.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }) {
            return "This domain already has a mapping."
        }
        guard let port = Int(draft.port), (1...65535).contains(port) else { return "Enter a port between 1 and 65535." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit Domain" : "Add Domain").font(.headline)
                Spacer()
            }.padding()
            Form {
                Section {
                    TextField("Domain", text: $draft.domain, prompt: Text("bbq.test")).focused($domainFocused)
                    Picker("Container", selection: $draft.containerID) {
                        Text("Choose a Container").tag("")
                        ForEach(store.containers) { container in
                            Text(container.title + (container.running ? "" : " (Stopped)")).tag(container.id)
                        }
                    }
                    .onChange(of: draft.containerID) { _, value in
                        if let container = store.containers.first(where: { $0.id == value }) {
                            draft.port = String(container.preferredPort)
                        }
                    }
                    TextField("Container Port", text: $draft.port)
                } footer: {
                    if let container = store.containers.first(where: { $0.id == draft.containerID }), !container.ports.isEmpty {
                        Text("Available ports: " + container.ports.map(String.init).joined(separator: ", "))
                    }
                }
                Section {
                    Toggle("Use HTTPS to connect to container", isOn: $draft.upstreamTLS)
                    Toggle("Enable domain", isOn: $draft.enabled)
                }
                if let validation {
                    Section { Label(validation, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                }
                if let error = store.error {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add") { Task { await store.save(draft) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.domain.isEmpty || draft.containerID.isEmpty || validation != nil || store.busy)
            }.padding()
        }
        .frame(width: 480, height: 380)
        .onAppear { domainFocused = true; store.error = nil }
    }
}

struct SettingsPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { store.loginEnabled }, set: { store.setLogin($0) }))
                Toggle("Enable routing", isOn: Binding(
                    get: { store.routingEnabled },
                    set: { _ in Task { await store.pauseOrResume() } }
                )).disabled(store.busy)
            }
            Section("Local Domains") {
                LabeledContent("DNS", value: store.resolverInstalled ? "Configured" : "Not Configured")
                if !store.resolverInstalled {
                    Button("Set Up Local Domains…") { Task { await store.setUpDNS() } }.disabled(store.busy)
                }
            }
            Section {
                Button("Open Configuration Folder") { NSWorkspace.shared.open(store.directory) }
                Button("Remove Local Setup…", role: .destructive) { confirmingRemoval = true }.disabled(store.busy)
            } footer: {
                Text("Removing the local setup keeps your saved domains and containers.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 360)
        .safeAreaInset(edge: .bottom, spacing: 0) { OperationError() }
        .confirmationDialog("Remove local domain routing?", isPresented: $confirmingRemoval) {
            Button("Remove Local Setup", role: .destructive) { Task { await store.uninstall() } }
        } message: {
            Text("Local domains will stop working until you set them up again.")
        }
    }
}

private struct OperationError: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        if let error = store.error, store.editor == nil {
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).textSelection(.enabled).lineLimit(4)
                    Spacer()
                    Button("Dismiss") { store.error = nil }
                }.padding()
            }.background(.bar)
        }
    }
}
