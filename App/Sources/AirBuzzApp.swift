import SwiftUI

@main
struct AirBuzzApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { _ = AirLink.shared }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { Task { await Telemetry.shared.capture("app_opened") } }
        }
    }
}
