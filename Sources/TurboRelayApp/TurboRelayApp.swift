import SwiftUI
import TurboRelayCore

@main
struct TurboRelayApp: App {
    @StateObject private var controller = RelayController()

    var body: some Scene {
        MenuBarExtra("TurboRelay", systemImage: "desktopcomputer.and.arrow.down") {
            Section {
                Text(controller.statusLine)
                Text(controller.loadedLine)
            }
            Section {
                Button("Copy Pairing Token") { controller.copyToken() }
                Button("Open Staging Folder") { controller.openStaging() }
            }
            Section {
                Button("Quit TurboRelay") { controller.quit() }
            }
        }
    }
}

@MainActor
final class RelayController: ObservableObject {
    @Published private(set) var statusLine = "Starting…"
    @Published private(set) var loadedLine = "No model in memory"
    private let service: RelayService
    private let token: String
    private let staging: URL

    init() {
        let home = RelayHome.ensureDirectories()
        let config = RelayConfig.load(home: home)
        token = config.token
        staging = config.stagingURL
        service = RelayService(home: home, config: config)
        service.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        do {
            try service.start()
        } catch {
            statusLine = "Could not start: \(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() {
        statusLine = service.statusSummary()
        loadedLine = service.loadedModelName().map { "In memory: \($0)" } ?? "No model in memory"
    }

    func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }

    func openStaging() {
        NSWorkspace.shared.open(staging)
    }

    func quit() {
        service.stop()
        NSApplication.shared.terminate(nil)
    }
}
