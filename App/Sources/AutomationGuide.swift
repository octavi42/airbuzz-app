import SwiftUI
import UIKit

struct AutomationGuide: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var app = "Any app"
    @State private var copied = false

    private let apps = ["Any app", "Messages", "WhatsApp", "Telegram", "Signal", "Slack", "Mail", "Instagram", "Discord"]

    private var anyApp: Bool { app == "Any app" }

    private var prompt: String {
        let trigger = anyApp ? "any app" : app
        return "When I get a notification from \(trigger), Buzz my Air with AirBuzz. Run immediately, without asking or notifying. Buzz my Air with AirBuzz is an action from the AirBuzz app, not a shortcut."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("AirBuzz copies a ready prompt. In Shortcuts, paste it into Describe a shortcut. Do this once per app.")
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("App")
                        Spacer()
                        Picker("App", selection: $app) {
                            ForEach(apps, id: \.self) { Text($0).tag($0) }
                        }
                        .tint(.primary)
                    }

                    Text(prompt)
                        .font(.body)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
                        .textSelection(.enabled)

                    DisclosureGroup("Set it up by hand") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("1. Automation, then +, then Notification.")
                            Text(anyApp ? "2. Select every app you want, and Run Immediately." : "2. Choose \(app) and Run Immediately.")
                            Text("3. Add action, search AirBuzz, pick Buzz My Air (not Run Shortcut).")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .tint(.primary)
                }
                .padding(24)
            }
            .navigationTitle("Buzz on notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button { copyAndOpen() } label: {
                    Label(copied ? "Copied, paste it in Shortcuts" : "Copy prompt and open Shortcuts",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(colors: [Color.inkTop, Color.ink], startPoint: .top, endPoint: .bottom),
                            in: .capsule)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressableStyle(scale: 0.98))
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .animation(.easeOut(duration: 0.25), value: copied)
            }
            .onChange(of: app) { copied = false }
        }
    }

    private func copyAndOpen() {
        UIPasteboard.general.string = prompt
        copied = true
        let everyApp = anyApp
        Task { await Telemetry.shared.capture("automation_prompt_copied", ["any_app": .bool(everyApp)]) }
        if let url = URL(string: "shortcuts://create-shortcut") { openURL(url) }
    }
}
