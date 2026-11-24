import Foundation

/// Anonymous usage events sent straight to PostHog's capture API (no SDK).
/// Sends a random install ID, app and iOS version, device model and what the band did.
/// Never sends notification content, app names, band identifiers or anything about the user.
/// Events wait on disk until PostHog accepts them, so a buzz that runs offline is sent later.
actor Telemetry {
    static let shared = Telemetry()
    static let optOutKey = "telemetryOff"

    enum Value: Encodable, Sendable {
        case string(String), number(Double), bool(Bool)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            }
        }
    }

    private struct Event: Encodable {
        let event: String
        let timestamp: String
        let properties: [String: Value]
    }

    private struct Batch: Encodable {
        let api_key: String
        let batch: [Event]
    }

    private let defaults = UserDefaults.standard
    private let pendingKey = "telemetryPending"
    private let maxPending = 200
    private var sending = false

    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: optOutKey) }
        set { UserDefaults.standard.set(!newValue, forKey: optOutKey) }
    }

    private var apiKey: String { Bundle.main.object(forInfoDictionaryKey: "PostHogKey") as? String ?? "" }
    private var host: String { Bundle.main.object(forInfoDictionaryKey: "PostHogHost") as? String ?? "" }

    private var installID: String {
        if let id = defaults.string(forKey: "telemetryInstallID") { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "telemetryInstallID")
        return id
    }

    /// Queues one event and tries to send everything waiting. Returns once the send finished or failed.
    func capture(_ name: String, _ extra: [String: Value] = [:]) async {
        guard Self.isEnabled, !apiKey.isEmpty, !host.isEmpty else { return }
        var properties = baseProperties()
        properties.merge(extra) { _, new in new }
        let event = Event(event: name, timestamp: ISO8601DateFormatter().string(from: Date()), properties: properties)
        guard let data = try? JSONEncoder().encode(event) else { return }
        var pending = defaults.array(forKey: pendingKey) as? [Data] ?? []
        pending.append(data)
        defaults.set(Array(pending.suffix(maxPending)), forKey: pendingKey)
        await flush()
    }

    /// Sends waiting events. Safe to call any time; does nothing when opted out or already sending.
    func flush() async {
        guard Self.isEnabled, !sending, !apiKey.isEmpty, let url = URL(string: host + "/batch/") else { return }
        let pending = defaults.array(forKey: pendingKey) as? [Data] ?? []
        guard !pending.isEmpty else { return }
        sending = true
        defer { sending = false }
        let events = pending.compactMap { try? JSONSerialization.jsonObject(with: $0) }
        guard let body = try? JSONSerialization.data(withJSONObject: ["api_key": apiKey, "batch": events]) else { return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return }
        let now = defaults.array(forKey: pendingKey) as? [Data] ?? []
        defaults.set(Array(now.dropFirst(pending.count)), forKey: pendingKey)
    }

    /// Drops anything still waiting, used when the user turns sharing off.
    func clear() { defaults.removeObject(forKey: pendingKey) }

    private func baseProperties() -> [String: Value] {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "distinct_id": .string(installID),
            "$process_person_profile": .bool(false),
            "$lib": .string("airbuzz-ios"),
            "app_version": .string(info["CFBundleShortVersionString"] as? String ?? "?"),
            "app_build": .string(info["CFBundleVersion"] as? String ?? "?"),
            "$os": .string("iOS"),
            "$os_version": .string("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            "$device_model": .string(Self.deviceModel),
        ]
    }

    private static let deviceModel: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()
}
