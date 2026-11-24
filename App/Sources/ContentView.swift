import SwiftUI

struct ContentView: View {
    @State private var status = AirStatus.shared
    @State private var running = false
    @State private var mode: BuzzMode = .single
    @State private var showSetup = false
    @State private var showLog = false
    @State private var taps = 0
    @State private var sharing = Telemetry.isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                VStack(spacing: 0) {
                    StatusPill(status: status).padding(.top, 8)

                    Spacer()

                    PulseButton(running: running, trigger: taps, reduceMotion: reduceMotion) {
                        taps += 1
                        run(read: false)
                    }

                    lastResult
                        .frame(height: 48)
                        .padding(.top, 24)

                    Spacer()

                    ModeToggle(mode: $mode).padding(.bottom, 20)
                    notificationsButton
                }
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Read strength", systemImage: "gauge.with.dots.needle.33percent") { run(read: true) }
                            .disabled(running)
                        Button("Activity", systemImage: "list.bullet") { showLog = true }
                        Toggle("Share anonymous usage", systemImage: "chart.bar", isOn: $sharing)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $showSetup) { AutomationGuide() }
            .sheet(isPresented: $showLog) { ActivityLog(status: status) }
            .sensoryFeedback(.impact(weight: mode == .double ? .heavy : .medium), trigger: taps)
            .onChange(of: sharing) { _, on in
                Telemetry.isEnabled = on
                if !on { Task { await Telemetry.shared.clear() } }
            }
        }
    }

    @ViewBuilder private var lastResult: some View {
        Group {
            if running {
                Text(status.status)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            } else if let result = status.lastResult {
                VStack(spacing: 3) {
                    Text(result).font(.callout.weight(.medium))
                    if let seconds = status.lastSeconds {
                        Text("\(seconds, format: .number.precision(.fractionLength(1))) s")
                            .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            } else {
                Text("Tap to buzz your band").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .transition(.opacity.combined(with: .offset(y: 4)))
        .animation(.easeOut(duration: 0.25), value: running)
        .animation(.easeOut(duration: 0.25), value: status.lastResult)
    }

    private var notificationsButton: some View {
        Button { showSetup = true } label: {
            Label("Buzz on notifications", systemImage: "bell.badge")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(.quaternary.opacity(0.5), in: .capsule)
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private func run(read: Bool) {
        guard !running else { return }
        running = true
        Task {
            defer { running = false }
            do {
                if read { _ = try await AirLink.shared.readIntensity() }
                else { _ = try await AirLink.shared.buzz(mode) }
            } catch {
                // AirLink publishes the readable error and completion time.
            }
        }
    }
}

// MARK: - Hero buzz button (the AirBuzz mark)

private struct PulseButton: View {
    let running: Bool
    let trigger: Int
    let reduceMotion: Bool
    let action: () -> Void

    @State private var tapTimes: [Date] = []
    @State private var runStart: Date?
    @State private var runEnd: Date?

    var body: some View {
        Button(action: action) {
            PillField(tapTimes: tapTimes, runStart: runStart, runEnd: runEnd, reduceMotion: reduceMotion)
                .frame(width: 360, height: 360)
                .contentShape(Circle().inset(by: 70))
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .disabled(running)
        .accessibilityLabel("Test buzz")
        .onChange(of: trigger) {
            let now = Date()
            tapTimes = tapTimes.filter { now.timeIntervalSince($0) < 2 } + [now]
        }
        .onChange(of: running) { _, isRunning in
            if isRunning { runStart = Date(); runEnd = nil } else { runEnd = Date() }
        }
    }
}

// MARK: - Mode toggle

private struct ModeToggle: View {
    @Binding var mode: BuzzMode
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            segment("Single", .single)
            segment("Double", .double)
        }
        .padding(4)
        .background(.quaternary.opacity(0.5), in: .capsule)
    }

    private func segment(_ title: String, _ value: BuzzMode) -> some View {
        let selected = mode == value
        return Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? Color(.systemBackground) : .primary)
            .frame(width: 94, height: 36)
            .background {
                if selected {
                    Capsule().fill(Color.primary)
                        .matchedGeometryEffect(id: "segment", in: ns)
                }
            }
            .contentShape(.capsule)
            .onTapGesture {
                withAnimation(.spring(duration: 0.35, bounce: 0.22)) { mode = value }
            }
    }
}

// MARK: - Status pill

private struct StatusPill: View {
    let status: AirStatus

    private var state: (String, Color) {
        if !status.bluetoothOn { return (status.bluetooth, .red) }
        if status.linked { return ("Fitbit Air ready", .green) }
        if status.bandFound { return ("Connecting", .orange) }
        return ("Looking for Fitbit Air", .secondary)
    }

    private var busy: Bool { status.bluetoothOn && !status.linked }

    var body: some View {
        let (text, color) = state
        HStack(spacing: 8) {
            ZStack {
                if busy {
                    Circle()
                        .stroke(color, lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                        .phaseAnimator([false, true]) { ring, phase in
                            ring.scaleEffect(phase ? 2.4 : 1).opacity(phase ? 0 : 0.7)
                        } animation: { _ in .easeOut(duration: 1.1) }
                }
                Circle().fill(color).frame(width: 9, height: 9)
            }
            .frame(width: 9, height: 9)

            Text(text)
                .font(.subheadline.weight(.medium))
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: .capsule)
        .animation(.easeOut(duration: 0.3), value: text)
    }
}

// MARK: - Activity log

private struct ActivityLog: View {
    let status: AirStatus
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(status.lines.reversed()) { line in
                Text(line.text).font(.caption.monospaced()).textSelection(.enabled)
            }
            .overlay {
                if status.lines.isEmpty { ContentUnavailableView("No activity yet", systemImage: "list.bullet") }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
