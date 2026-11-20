import SwiftUI

@main
struct CVMControlApp: App {
    @StateObject private var client = TelnetClient()

    init() {
        // Bring to front when launched as a bare executable (e.g. `swift run`).
        DispatchQueue.main.async { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("CVM Control") {
            ContentView()
                .environmentObject(client)
                .frame(minWidth: 820, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
    }
}
