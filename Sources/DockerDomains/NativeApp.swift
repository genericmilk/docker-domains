import AppKit
import SwiftUI

@main
struct DockerDomainsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore.shared

    var body: some Scene {
        domainsWindow

        MenuBarExtra("Docker Domains", systemImage: "network") {
            DomainMenu().environmentObject(store)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsPanel().environmentObject(store)
        }
    }

    private var domainsWindow: some Scene {
        Window("Docker Domains", id: "domains") {
            DomainsWindow().environmentObject(store)
        }
        .defaultSize(width: 780, height: 540)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppStore.shared.boot()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = sender.windows.first(where: { $0.title == "Docker Domains" || $0.identifier?.rawValue == "domains" }) {
            window.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }
}
