import AppIntents

enum BuzzMode: String, AppEnum {
    case single
    case double

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Buzz mode"
    static let caseDisplayRepresentations: [BuzzMode: DisplayRepresentation] = [
        .single: "Single tap", .double: "Double"
    ]
}

struct BuzzMyAirIntent: AppIntent {
    static let title: LocalizedStringResource = "Buzz My Air"
    static let description = IntentDescription("Pulse your Fitbit Air, then return its tracker channel to Google Health.")
    static let openAppWhenRun = false

    @Parameter(title: "Mode") var mode: BuzzMode?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let intensity = try await AirLink.shared.buzz(mode ?? .single, source: .automation)
        let strength = intensity == 2 ? "low" : "high"
        return .result(dialog: "Air buzzed. Strength restored to \(strength).")
    }
}

struct AirBuzzShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: BuzzMyAirIntent(),
            phrases: ["Buzz my Air with \(.applicationName)", "Make my Air buzz with \(.applicationName)"],
            shortTitle: "Buzz My Air",
            systemImageName: "waveform"
        )
    }
}
