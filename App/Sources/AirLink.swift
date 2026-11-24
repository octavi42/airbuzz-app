import Foundation
@preconcurrency import CoreBluetooth

struct AirFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

final class RequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

final class CoreContext: @unchecked Sendable {
    let owner: AirLink
    let requestID: UUID
    init(owner: AirLink, requestID: UUID) {
        self.owner = owner
        self.requestID = requestID
    }
}

// All mutable transport state belongs exclusively to queue. C callbacks copy
// their borrowed buffers before crossing from the Golden Gate thread.
final class AirLink: NSObject, @unchecked Sendable {
    static let shared = AirLink()
    static let serviceID = CBUUID(string: "abbaff00-e56a-484c-b832-8b17cf6cbfe8")
    static let txID = CBUUID(string: "abbaff01-e56a-484c-b832-8b17cf6cbfe8")
    static let rxID = CBUUID(string: "abbaff02-e56a-484c-b832-8b17cf6cbfe8")
    enum Operation: Sendable { case read, tap, double }
    struct Request: Sendable {
        let id: UUID
        let operation: Operation
        let continuation: CheckedContinuation<Int, Error>
    }
    let queue = DispatchQueue(label: "com.tavi.airbuzz.bluetooth")
    var central: CBCentralManager!
    var requests: [Request] = []
    var active: Request?
    var peripheral: CBPeripheral?
    var tx: CBCharacteristic?
    var rx: CBCharacteristic?
    var packets: [Data] = []
    var session: OpaquePointer?
    var context: UnsafeMutableRawPointer?
    var deadline: DispatchWorkItem?
    var abortResult: Result<Int, Error>?
    var scanDeadline: DispatchWorkItem?
    var disconnectDeadline: DispatchWorkItem?
    var awaitingDisconnect = false
    var maxPacketSize = 0
    var startedAt: DispatchTime?
    var linkReady = false
    var reportedFound = false
    var reportedLinked = false

    var isWarm: Bool {
        linkReady && peripheral?.state == .connected && tx != nil && rx?.isNotifying == true
    }

    private override init() {
        super.init()
        queue.async {
            self.central = CBCentralManager(delegate: self, queue: self.queue, options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.tavi.airbuzz.central"
            ])
        }
    }

    enum Source: String, Sendable { case app, automation }

    func buzz(_ mode: BuzzMode = .single, source: Source = .app) async throws -> Int {
        try await tracked(mode == .single ? .tap : .double, source: source)
    }

    func readIntensity() async throws -> Int { try await tracked(.read, source: .app) }

    /// Runs an operation and reports how it went. Automations wait for the report so it is
    /// sent before iOS suspends the intent; the in-app button does not wait.
    private func tracked(_ operation: Operation, source: Source) async throws -> Int {
        let started = Date()
        var properties: [String: Telemetry.Value] = [
            "operation": .string("\(operation)"), "source": .string(source.rawValue),
        ]
        let result: Result<Int, Error>
        do { result = .success(try await perform(operation)) } catch { result = .failure(error) }
        properties["seconds"] = .number((Date().timeIntervalSince(started) * 10).rounded() / 10)
        switch result {
        case .success: properties["ok"] = .bool(true)
        case .failure(let error):
            properties["ok"] = .bool(false)
            properties["error"] = .string(error is CancellationError ? "cancelled" : error.localizedDescription)
        }
        let report = Task { await Telemetry.shared.capture("band_action", properties) }
        if source == .automation { await report.value }
        return try result.get()
    }

    private func perform(_ operation: Operation) async throws -> Int {
        let id = UUID()
        let cancellation = RequestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.requests.append(Request(id: id, operation: operation, continuation: continuation))
                    self.startNext()
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.queue.async {
                if self.active?.id == id {
                    self.finish(.failure(CancellationError()))
                } else if let index = self.requests.firstIndex(where: { $0.id == id }) {
                    self.requests.remove(at: index).continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    func startNext() {
        guard active == nil, !awaitingDisconnect, !requests.isEmpty else { return }
        active = requests.removeFirst()
        let id = active!.id
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.active?.id == id else { return }
            self.finish(.failure(AirFailure(message: "The band did not finish within 25 seconds. Try again.")))
        }
        deadline = timeout
        queue.asyncAfter(deadline: .now() + 25, execute: timeout)
        startedAt = .now()
        publish(isWarm ? "Link already open" : "Preparing Bluetooth")
        findBand()
    }

    func findBand() {
        guard active != nil else { return }
        switch central.state {
        case .poweredOn:
            if peripheral != nil || retrieveBand() {
                if isWarm { beginSession() } else { ensureLink() }
                return
            }
            guard !central.isScanning else { return }
            publish("Scanning for Fitbit Air")
            central.scanForPeripherals(withServices: [Self.serviceID])
            let id = active!.id
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.active?.id == id, self.peripheral == nil else { return }
                self.finish(.failure(AirFailure(message: "No Fitbit Air found. Keep the band nearby and try again.")))
            }
            scanDeadline = timeout
            queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        case .unauthorized:
            finish(.failure(AirFailure(message: "Allow Bluetooth access for AirBuzz in Settings.")))
        case .poweredOff:
            finish(.failure(AirFailure(message: "Turn on Bluetooth to reach your Fitbit Air.")))
        case .unsupported:
            finish(.failure(AirFailure(message: "This device does not support Bluetooth LE.")))
        case .unknown, .resetting: break
        @unknown default: break
        }
    }

    /// Keeps the band connected and subscribed between operations so a buzz
    /// skips connection, discovery and subscription (the warm link).
    func ensureLink() {
        guard central.state == .poweredOn else { return }
        guard let band = peripheral else { _ = retrieveBand(); return }
        switch band.state {
        case .connected:
            if isWarm {
                if active != nil { beginSession() }
            } else if let rx, tx != nil {
                if rx.isNotifying { markReady() } else { band.setNotifyValue(true, for: rx) }
            } else {
                band.discoverServices([Self.serviceID])
            }
        case .disconnected:
            central.connect(band)
        default:
            break
        }
    }

    func retrieveBand() -> Bool {
        guard let band = central.retrieveConnectedPeripherals(withServices: [Self.serviceID]).first else { return false }
        connect(band)
        return true
    }

    func markReady() {
        linkReady = true
        log("Band link ready")
        if !reportedLinked {
            reportedLinked = true
            Task { await Telemetry.shared.capture("band_linked") }
        }
        Task { @MainActor in AirStatus.shared.linked = true }
        if active != nil { beginSession() }
    }

    func resetLink() {
        linkReady = false
        tx = nil
        rx = nil
        Task { @MainActor in AirStatus.shared.linked = false }
    }

    func connect(_ band: CBPeripheral) {
        central.stopScan()
        scanDeadline?.cancel()
        peripheral = band
        band.delegate = self
        if !reportedFound {
            reportedFound = true
            Task { await Telemetry.shared.capture("band_found") }
        }
        let description = "Band found: \(band.name ?? "Fitbit Air")"
        Task { @MainActor in AirStatus.shared.band = description }
        publish(description)
        central.connect(band)
    }

    func beginSession() {
        guard session == nil, let active, let peripheral, let tx, let rx,
              rx.isNotifying, tx.properties.contains(.writeWithoutResponse) else { return }
        maxPacketSize = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard maxPacketSize > 0 else {
            finish(.failure(AirFailure(message: "The band did not negotiate a packet size.")))
            return
        }
        let box = CoreContext(owner: self, requestID: active.id)
        context = Unmanaged.passRetained(box).toOpaque()
        session = AB_Session_Create({ raw, bytes, count in
            guard let raw, let bytes else { return }
            let box = Unmanaged<CoreContext>.fromOpaque(raw).takeUnretainedValue()
            let packet = Data(bytes: bytes, count: count)
            box.owner.queue.async {
                guard box.owner.active?.id == box.requestID else { return }
                box.owner.send(packet)
            }
        }, { raw, result, intensity, message in
            guard let raw else { return }
            let box = Unmanaged<CoreContext>.fromOpaque(raw).takeUnretainedValue()
            let text = message.map { String(cString: $0) } ?? "Band operation failed."
            box.owner.queue.async {
                guard box.owner.active?.id == box.requestID else { return }
                if result == AB_OK {
                    box.owner.finish(.success(Int(intensity)), coreDone: true)
                } else {
                    box.owner.finish(.failure(AirFailure(message: text)), coreDone: true)
                }
            }
        }, { raw, line in
            guard let raw, let line else { return }
            let box = Unmanaged<CoreContext>.fromOpaque(raw).takeUnretainedValue()
            let text = String(cString: line)
            box.owner.queue.async {
                guard box.owner.active?.id == box.requestID else { return }
                box.owner.log(text)
            }
        }, context, maxPacketSize)
        guard let session else {
            finish(.failure(AirFailure(message: "Could not create the band session.")))
            return
        }
        let operation: AB_Operation = switch active.operation {
        case .read: AB_OP_READ
        case .tap: AB_OP_TAP
        case .double: AB_OP_DOUBLE
        }
        publish("Talking to band (\(maxPacketSize)-byte packets)")
        if AB_Session_Start(session, operation) != AB_OK {
            finish(.failure(AirFailure(message: "Could not start the band session.")))
        }
    }

    func send(_ packet: Data) {
        guard canTransmit() else { return }
        guard packet.count <= maxPacketSize else {
            finish(.failure(AirFailure(message: "The core emitted an oversized Bluetooth packet.")))
            return
        }
        guard packets.count < 512 else {
            finish(.failure(AirFailure(message: "Bluetooth could not keep up with the band.")))
            return
        }
        packets.append(packet)
        flushPackets()
    }

    func flushPackets() {
        guard canTransmit() else { return }
        guard let peripheral, let tx, peripheral.state == .connected else { return }
        while peripheral.canSendWriteWithoutResponse, !packets.isEmpty {
            guard canTransmit() else { return }
            peripheral.writeValue(packets.removeFirst(), for: tx, type: .withoutResponse)
        }
    }

    func canTransmit() -> Bool {
        guard let session, AB_Session_IsMuted(session) == 0 else {
            packets.removeAll()
            return false
        }
        return true
    }

    func finish(_ proposedResult: Result<Int, Error>, coreDone: Bool = false) {
        guard let request = active else { return }
        // Leave RX and TX running while the core restores and releases the channel.
        if let session, !coreDone {
            guard abortResult == nil else { return }
            abortResult = proposedResult
            deadline?.cancel()
            AB_Session_Abort(session)
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.active?.id == request.id else { return }
                self.finish(proposedResult, coreDone: true)
            }
            deadline = timeout
            queue.asyncAfter(deadline: .now() + 3, execute: timeout)
            return
        }
        let result = abortResult ?? proposedResult
        let keepWarm = if case .success = result { true } else { false }
        abortResult = nil
        active = nil
        deadline?.cancel()
        scanDeadline?.cancel()
        central.stopScan()
        if let session {
            AB_Session_Destroy(session)
            self.session = nil
        }
        if let context {
            Unmanaged<CoreContext>.fromOpaque(context).release()
            self.context = nil
        }
        packets.removeAll()
        if !keepWarm, let peripheral {
            if let rx, rx.isNotifying, peripheral.state == .connected {
                peripheral.setNotifyValue(false, for: rx)
            }
            awaitingDisconnect = true
            central.cancelPeripheralConnection(peripheral)
            let timeout = DispatchWorkItem { [weak self] in self?.releaseConnection() }
            disconnectDeadline = timeout
            queue.asyncAfter(deadline: .now() + 2, execute: timeout)
            resetLink()
        }
        let summary: String
        switch result {
        case .success(let intensity): summary = "Finished. Strength: \(intensity == 2 ? "Low" : "High")"
        case .failure(let error): summary = error.localizedDescription
        }
        publish(summary)
        let seconds = startedAt.map { Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1e9 }
        startedAt = nil
        Task { @MainActor in AirStatus.shared.recordResult(summary, seconds: seconds) }
        request.continuation.resume(with: result)
        if !awaitingDisconnect { startNext() }
    }

    func releaseConnection() {
        disconnectDeadline?.cancel()
        peripheral?.delegate = nil
        peripheral = nil
        awaitingDisconnect = false
        resetLink()
        startNext()
        if active == nil { ensureLink() }
    }

    func publish(_ status: String) {
        log(status)
        Task { @MainActor in AirStatus.shared.status = status }
    }

    func log(_ line: String) {
        var text = line
        if active != nil, let startedAt {
            let ms = (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
            text = "+\(ms) ms  \(line)"
        }
        Task { @MainActor in AirStatus.shared.append(text) }
    }
}
