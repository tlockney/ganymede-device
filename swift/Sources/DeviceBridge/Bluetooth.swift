import CoreBluetooth
import Foundation

// `device.bluetooth` (docs/protocol.md, "Bluetooth"): a Bluetooth LE
// central over Core Bluetooth. `scan` streams advertisements, `known`
// finds peripherals by id, and `connect` opens a handle (Handles.swift)
// that `services`, `read`, `write`, `notify` and `rssi` name. Scanning,
// `known` and connecting need the bluetooth permission (and the ledger's
// grant); a handle's calls need only the handle. When the link drops,
// the handle's waiting calls reject `disconnected`, its `notify` streams
// end with it, and the handle closes. The app turns the namespace on with
// `DeviceBridge.addBluetooth()`.

/// One advertisement a scan heard.
public struct BluetoothAdvertisement: Sendable, Equatable {
    public var id: UUID
    public var name: String?
    public var rssi: Int
    /// Service UUIDs, as Core Bluetooth writes them ("180D", or the full form).
    public var services: [String]
    public var manufacturerData: Data?
    /// Service data by service UUID.
    public var serviceData: [String: Data]

    public init(id: UUID, name: String?, rssi: Int, services: [String] = [], manufacturerData: Data? = nil, serviceData: [String: Data] = [:]) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.services = services
        self.manufacturerData = manufacturerData
        self.serviceData = serviceData
    }
}

/// A peripheral the system already knows, by id.
public struct BluetoothKnownPeripheral: Sendable, Equatable {
    public var id: UUID
    public var name: String?

    public init(id: UUID, name: String?) {
        self.id = id
        self.name = name
    }
}

/// A characteristic, with what it allows: `read`, `write`,
/// `writeWithoutResponse`, `notify`, `indicate`.
public struct BluetoothCharacteristicInfo: Sendable, Equatable {
    public var uuid: String
    public var properties: [String]

    public init(uuid: String, properties: [String]) {
        self.uuid = uuid
        self.properties = properties
    }
}

/// A service and its characteristics.
public struct BluetoothServiceInfo: Sendable, Equatable {
    public var uuid: String
    public var characteristics: [BluetoothCharacteristicInfo]

    public init(uuid: String, characteristics: [BluetoothCharacteristicInfo]) {
        self.uuid = uuid
        self.characteristics = characteristics
    }
}

/// The central, and the bluetooth permission, behind a protocol so tests
/// needn't use the radio.
@MainActor
public protocol BluetoothCentral: Permission {
    /// `done(nil)` once the radio is on; otherwise with why calls fail
    /// (`unavailable` while it is off or unsupported). Waits while the
    /// radio's state is still unknown.
    func ready(_ done: @escaping @MainActor (DeviceCallError?) -> Void)
    /// Advertisements until the source is stopped, or `failed` ends it.
    /// `services` filters by service UUID; without `allowDuplicates`,
    /// each peripheral once.
    func scan(
        services: [String]?, allowDuplicates: Bool, found: @escaping @MainActor (BluetoothAdvertisement) -> Void,
        failed: @escaping @MainActor (DeviceCallError) -> Void
    ) -> StreamSource
    /// The peripherals with these ids the system knows.
    func known(_ ids: [UUID]) -> [BluetoothKnownPeripheral]
    /// Connects; `done` once, unless the returned cancel runs first.
    func connect(_ id: UUID, timeout: TimeInterval, done: @escaping @MainActor (Result<BluetoothPeripheral, DeviceCallError>) -> Void) -> () -> Void
}

/// A connected peripheral. Each call answers once, unless its returned
/// cancel runs first. When the link drops, waiting calls fail
/// `disconnected`, `notify` sources end with it, and `onDisconnect` runs;
/// after `disconnect()`, waiting calls fail and `notify` sources end
/// without an error, and `onDisconnect` doesn't run.
@MainActor
public protocol BluetoothPeripheral: AnyObject {
    var id: UUID { get }
    var name: String? { get }
    var onDisconnect: (@MainActor (DeviceCallError) -> Void)? { get set }
    /// Discovered once, then cached.
    func services(_ done: @escaping @MainActor (Result<[BluetoothServiceInfo], DeviceCallError>) -> Void) -> () -> Void
    func read(service: String, characteristic: String, done: @escaping @MainActor (Result<Data, DeviceCallError>) -> Void) -> () -> Void
    func write(
        service: String, characteristic: String, data: Data, withResponse: Bool,
        done: @escaping @MainActor (Result<Void, DeviceCallError>) -> Void
    ) -> () -> Void
    /// Values until the source is stopped; `ended` once, with an error or
    /// without (after `disconnect()`).
    func notify(
        service: String, characteristic: String, update: @escaping @MainActor (Data) -> Void,
        ended: @escaping @MainActor (DeviceCallError?) -> Void
    ) -> StreamSource
    func rssi(_ done: @escaping @MainActor (Result<Int, DeviceCallError>) -> Void) -> () -> Void
    func disconnect()
}

// MARK: The bridge's side

/// A bridge's open peripherals, by handle id.
@MainActor
final class BluetoothHub {
    /// The handle kind of a connected peripheral.
    static let kind = "bluetooth.peripheral"
    /// Peripherals one kernel may have connected at once.
    static let maxPeripherals = 8
    static let defaultTimeout: TimeInterval = 15

    let central: BluetoothCentral
    private let handles: Handles
    private var peripherals: [Int: BluetoothPeripheral] = [:]
    /// Handles whose peripheral went away, newest last, so a later call on
    /// one fails `disconnected` rather than as an unknown handle.
    private var dropped: [(handle: Int, owner: Int)] = []
    private static let maxDropped = 64

    init(central: BluetoothCentral, handles: Handles) {
        self.central = central
        self.handles = handles
    }

    /// `bluetooth.scan`: waits for the radio, then scans.
    func scan(_ params: [String: Any], sink: StreamSink) throws -> StreamSource {
        let (services, duplicates) = try Self.scanOptions(params)
        let scan = PendingScan()
        central.ready { [weak self, weak scan] error in
            guard let self, let scan, !scan.stopped else { return }
            if let error {
                sink.finish(error)
                return
            }
            scan.source = self.central.scan(
                services: services, allowDuplicates: duplicates,
                found: { sink.send(Self.advertisementReply($0)) },
                failed: { sink.finish($0) })
        }
        return scan
    }

    private final class PendingScan: StreamSource {
        var stopped = false
        var source: StreamSource?
        func stop() {
            stopped = true
            source?.stop()
            source = nil
        }
    }

    func known(_ params: [String: Any], reply: @escaping MethodReply) -> (() -> Void)? {
        let ids: [UUID]
        do {
            ids = try Self.ids(params["ids"])
        } catch {
            reply(.failure(error as? DeviceCallError ?? DeviceCallError("failed", "\(error)")))
            return nil
        }
        var cancelled = false
        central.ready { [weak self] error in
            guard let self, !cancelled else { return }
            if let error { return reply(.failure(error)) }
            reply(.success(self.central.known(ids).map { ["id": $0.id.uuidString, "name": $0.name ?? NSNull()] as [String: Any] }))
        }
        return { cancelled = true }
    }

    func connect(_ params: [String: Any], owner: Int, call: Int?, reply: @escaping MethodReply) -> (() -> Void)? {
        guard let text = params["id"] as? String, let id = UUID(uuidString: text) else {
            reply(.failure(DeviceCallError("failed", "bluetooth.connect needs a peripheral id (a UUID from scan or known)")))
            return nil
        }
        var timeout = Self.defaultTimeout
        if let value = params["timeout"], !(value is NSNull) {
            guard let n = Self.number(value), n >= 1, n <= 120 else {
                reply(.failure(DeviceCallError("failed", "bluetooth.connect: timeout must be 1 to 120 seconds")))
                return nil
            }
            timeout = n
        }
        guard handles.count(owner: owner, kind: Self.kind) < Self.maxPeripherals else {
            reply(.failure(Self.tooMany))
            return nil
        }
        var cancelled = false
        var cancelConnect: (() -> Void)?
        central.ready { [weak self] error in
            guard let self, !cancelled else { return }
            if let error { return reply(.failure(error)) }
            cancelConnect = self.central.connect(id, timeout: timeout) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .failure(error):
                    reply(.failure(error))
                case let .success(peripheral):
                    self.opened(peripheral, owner: owner, call: call, reply: reply)
                }
            }
        }
        return {
            cancelled = true
            cancelConnect?()
        }
    }

    /// `call` is the connect's id: a cancel that crosses the reply closes
    /// the handle the page never got.
    private func opened(_ peripheral: BluetoothPeripheral, owner: Int, call: Int?, reply: MethodReply) {
        let opened = handles.open(owner: owner, kind: Self.kind, limit: Self.maxPeripherals, call: call) { [weak self] id in
            self?.peripherals.removeValue(forKey: id)?.disconnect()
        }
        guard let handle = opened else {
            peripheral.disconnect()
            reply(.failure(Self.tooMany))
            return
        }
        peripherals[handle] = peripheral
        peripheral.onDisconnect = { [weak self] _ in
            guard let self else { return }
            // Already dropped: closing only forgets it.
            self.peripherals[handle] = nil
            self.handles.close(handle, owner: owner, kind: Self.kind)
            // Later calls on it say why it's gone.
            self.dropped.append((handle, owner))
            if self.dropped.count > Self.maxDropped { self.dropped.removeFirst() }
        }
        reply(.success(["peripheral": handle, "id": peripheral.id.uuidString, "name": peripheral.name ?? NSNull()] as [String: Any]))
    }

    /// The peripheral a call names, when its kernel has it open.
    func peripheral(_ method: String, _ params: [String: Any], owner: Int) throws -> BluetoothPeripheral {
        let id = Self.number(params["peripheral"]).flatMap { Int(exactly: $0) }
        guard let id, handles.isOpen(id, owner: owner, kind: Self.kind), let peripheral = peripherals[id] else {
            if let id, dropped.contains(where: { $0.handle == id && $0.owner == owner }) {
                throw DeviceCallError("disconnected", "\(method): the peripheral disconnected")
            }
            throw DeviceCallError("failed", "\(method): no open peripheral with that id (it was closed)")
        }
        return peripheral
    }

    /// Runs one of a handle's calls: finds the peripheral, and turns a
    /// thrown error into the call's reply.
    func onPeripheral(
        _ method: String, _ params: [String: Any], _ context: CallContext, reply: @escaping MethodReply,
        _ body: (BluetoothPeripheral) throws -> () -> Void
    ) -> (() -> Void)? {
        do {
            return try body(peripheral(method, params, owner: context.owner))
        } catch {
            reply(.failure(error as? DeviceCallError ?? DeviceCallError("failed", "\(method): \(error)")))
            return nil
        }
    }

    /// The `service` and `characteristic` UUIDs a call names.
    static func characteristic(_ method: String, _ params: [String: Any]) throws -> (service: String, characteristic: String) {
        guard let service = params["service"] as? String, let characteristic = params["characteristic"] as? String else {
            throw DeviceCallError("failed", "\(method) needs a service and a characteristic UUID")
        }
        return (try uuid(method, service), try uuid(method, characteristic))
    }

    private static let tooMany = DeviceCallError(
        "failed", "bluetooth.connect: \(maxPeripherals) peripherals are connected; close one first")

    // MARK: Arguments and replies

    /// `services` and `allowDuplicates` of a `bluetooth.scan`.
    static func scanOptions(_ params: [String: Any]) throws -> (services: [String]?, allowDuplicates: Bool) {
        var services: [String]?
        if let value = params["services"], !(value is NSNull) {
            guard let list = value as? [Any] else {
                throw DeviceCallError("failed", "bluetooth.scan: services must be a list of UUIDs")
            }
            services = try list.map { item in
                guard let text = item as? String else {
                    throw DeviceCallError("failed", "bluetooth.scan: services must be a list of UUIDs")
                }
                return try uuid("bluetooth.scan", text)
            }
        }
        var duplicates = false
        if let value = params["allowDuplicates"], !(value is NSNull) {
            guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                throw DeviceCallError("failed", "bluetooth.scan: allowDuplicates must be true or false")
            }
            duplicates = flag.boolValue
        }
        return (services, duplicates)
    }

    /// The UUIDs of `bluetooth.known`.
    static func ids(_ value: Any?) throws -> [UUID] {
        guard let list = value as? [Any], list.count <= 64 else {
            throw DeviceCallError("failed", "bluetooth.known needs a list of at most 64 peripheral ids")
        }
        return try list.map { item in
            guard let text = item as? String, let id = UUID(uuidString: text) else {
                throw DeviceCallError("failed", "bluetooth.known: \(item) isn't a peripheral id (a UUID)")
            }
            return id
        }
    }

    /// A Bluetooth UUID, 16-bit ("180D"), 32-bit or 128-bit, upper-cased
    /// as Core Bluetooth writes it. Checked here: `CBUUID(string:)` raises
    /// on anything else.
    static func uuid(_ method: String, _ text: String) throws -> String {
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let short = (text.count == 4 || text.count == 8) && text.unicodeScalars.allSatisfy { hex.contains($0) }
        if short { return text.uppercased() }
        if let full = UUID(uuidString: text) {
            // The Bluetooth base UUID's short forms compare equal in Core
            // Bluetooth; keep what the cell wrote.
            return full.uuidString
        }
        throw DeviceCallError("failed", "\(method): \"\(text)\" isn't a Bluetooth UUID (\"180D\" or a full UUID)")
    }

    static func advertisementReply(_ ad: BluetoothAdvertisement) -> [String: Any] {
        var serviceData: [String: Any] = [:]
        for (uuid, data) in ad.serviceData { serviceData[uuid] = (try? DeviceBridge.binary(data)) ?? NSNull() }
        return [
            "id": ad.id.uuidString,
            "name": ad.name ?? NSNull(),
            "rssi": ad.rssi,
            "services": ad.services,
            "manufacturerData": ad.manufacturerData.flatMap { try? DeviceBridge.binary($0) } ?? NSNull(),
            "serviceData": serviceData,
        ]
    }

    static func servicesReply(_ services: [BluetoothServiceInfo]) -> [[String: Any]] {
        services.map { service in
            [
                "uuid": service.uuid,
                "characteristics": service.characteristics.map { ["uuid": $0.uuid, "properties": $0.properties] as [String: Any] },
            ]
        }
    }

    /// A number, not a boolean, which WebKit also hands over as an NSNumber.
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}

extension DeviceBridge {
    /// Turns on `device.bluetooth`: `hello` lists the trio, `bluetooth.scan`,
    /// `bluetooth.known`, `bluetooth.connect` and the handle's calls.
    /// `central` is Core Bluetooth by default, one per bridge; the app needs
    /// `NSBluetoothAlwaysUsageDescription` in its Info.plist, without which
    /// the permission stays `notDetermined` and calls are `denied`.
    public func addBluetooth(_ central: BluetoothCentral? = nil) {
        // Made here, not as the default argument: defaults are evaluated
        // outside the main actor.
        let hub = BluetoothHub(central: central ?? SystemBluetoothCentral(), handles: handles)
        addPermission("bluetooth", hub.central)
        addStream("bluetooth.scan", capacity: 128, permission: "bluetooth", check: { _ = try BluetoothHub.scanOptions($0) }) { params, sink in
            try hub.scan(params, sink: sink)
        }
        addMethod("bluetooth.known", permission: "bluetooth", check: { _ = try BluetoothHub.ids($0["ids"]) }) { params, reply in
            hub.known(params, reply: reply)
        }
        addMethod("bluetooth.connect", permission: "bluetooth") { params, context, reply in
            hub.connect(params, owner: context.owner, call: context.call, reply: reply)
        }
        addMethod("bluetooth.services") { params, context, reply in
            hub.onPeripheral("bluetooth.services", params, context, reply: reply) { peripheral in
                peripheral.services { reply($0.map { BluetoothHub.servicesReply($0) as Any }) }
            }
        }
        addMethod("bluetooth.read") { params, context, reply in
            hub.onPeripheral("bluetooth.read", params, context, reply: reply) { peripheral in
                let (service, characteristic) = try BluetoothHub.characteristic("bluetooth.read", params)
                return peripheral.read(service: service, characteristic: characteristic) { result in
                    reply(result.flatMap { data in
                        Result { try DeviceBridge.binary(data) as Any }.mapError { DeviceCallError("failed", "\($0)") }
                    })
                }
            }
        }
        addMethod("bluetooth.write") { params, context, reply in
            hub.onPeripheral("bluetooth.write", params, context, reply: reply) { peripheral in
                let (service, characteristic) = try BluetoothHub.characteristic("bluetooth.write", params)
                let data: Data
                do {
                    data = try DeviceBridge.bytes(params["data"])
                } catch {
                    throw DeviceCallError("failed", "bluetooth.write: \(error)")
                }
                let withResponse: Bool
                switch params["withResponse"] {
                case nil, is NSNull: withResponse = true
                case let flag as NSNumber where CFGetTypeID(flag) == CFBooleanGetTypeID(): withResponse = flag.boolValue
                default: throw DeviceCallError("failed", "bluetooth.write: withResponse must be true or false")
                }
                return peripheral.write(service: service, characteristic: characteristic, data: data, withResponse: withResponse) {
                    reply($0.map { NSNull() as Any })
                }
            }
        }
        addMethod("bluetooth.rssi") { params, context, reply in
            hub.onPeripheral("bluetooth.rssi", params, context, reply: reply) { peripheral in
                peripheral.rssi { reply($0.map { $0 as Any }) }
            }
        }
        addStream("bluetooth.notify", capacity: 256, ownedStart: { params, owner, sink in
            let peripheral = try hub.peripheral("bluetooth.notify", params, owner: owner)
            let (service, characteristic) = try BluetoothHub.characteristic("bluetooth.notify", params)
            return peripheral.notify(
                service: service, characteristic: characteristic,
                update: { data in
                    if let value = try? DeviceBridge.binary(data) { sink.send(value) }
                },
                ended: { sink.finish($0) })
        })
    }
}

// MARK: Core Bluetooth

/// Core Bluetooth's central. Its `CBCentralManager` is made on first use,
/// which is when the system asks for the permission.
@MainActor
public final class SystemBluetoothCentral: NSObject, BluetoothCentral, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var requests: [@MainActor (PermissionStatus) -> Void] = []
    private var readiness: [@MainActor (DeviceCallError?) -> Void] = []
    private var scans: [Scan] = []
    /// Peripherals heard or retrieved, so `connect` can find them by id.
    private var seen: [UUID: CBPeripheral] = [:]
    private var connecting: [UUID: Connecting] = [:]
    private var connected: [UUID: SystemBluetoothPeripheral] = [:]
    /// Links `disconnect()` let go of whose disconnect callback hasn't come:
    /// it is theirs, not a reconnect's under the same id.
    private var releasing: Set<UUID> = []

    private struct Connecting {
        let peripheral: CBPeripheral
        let done: @MainActor (Result<BluetoothPeripheral, DeviceCallError>) -> Void
        let timer: Timer
    }

    fileprivate final class Scan: StreamSource {
        let services: [CBUUID]?
        let allowDuplicates: Bool
        let found: @MainActor (BluetoothAdvertisement) -> Void
        let failed: @MainActor (DeviceCallError) -> Void
        var heard: Set<UUID> = []
        weak var central: SystemBluetoothCentral?

        init(
            services: [CBUUID]?, allowDuplicates: Bool, found: @escaping @MainActor (BluetoothAdvertisement) -> Void,
            failed: @escaping @MainActor (DeviceCallError) -> Void
        ) {
            self.services = services
            self.allowDuplicates = allowDuplicates
            self.found = found
            self.failed = failed
        }

        func stop() { central?.remove(self) }
    }

    override public init() {
        super.init()
    }

    /// Without it the system ends the app when the manager is made.
    private static var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    public var status: PermissionStatus {
        switch CBManager.authorization {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .allowedAlways: .authorized
        @unknown default: .denied
        }
    }

    public func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) {
        guard status == .notDetermined, Self.hasUsageDescription else {
            done(status)
            return
        }
        requests.append(done)
        // Making the manager is what asks.
        _ = makeManager()
    }

    private func makeManager() -> CBCentralManager? {
        if let manager { return manager }
        guard Self.hasUsageDescription else { return nil }
        let made = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        manager = made
        return made
    }

    public func ready(_ done: @escaping @MainActor (DeviceCallError?) -> Void) {
        guard let manager = makeManager() else {
            done(DeviceCallError("denied", "bluetooth: the app has no Bluetooth usage description"))
            return
        }
        if let error = Self.problem(manager.state) {
            done(error)
        } else if manager.state == .poweredOn {
            done(nil)
        } else {
            readiness.append(done)
        }
    }

    /// Why calls fail in `state`; nil while it is on, or not known yet.
    private static func problem(_ state: CBManagerState) -> DeviceCallError? {
        switch state {
        case .poweredOn, .unknown, .resetting: nil
        case .poweredOff: DeviceCallError("unavailable", "bluetooth: Bluetooth is off")
        case .unsupported: DeviceCallError("unavailable", "bluetooth: this device has no Bluetooth LE")
        case .unauthorized: DeviceCallError("denied", "bluetooth: the bluetooth permission is denied")
        @unknown default: DeviceCallError("unavailable", "bluetooth: the radio isn't ready")
        }
    }

    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { stateChanged() }
    }

    private func stateChanged() {
        guard let manager else { return }
        if status != .notDetermined, !requests.isEmpty {
            let waiting = requests
            requests = []
            for done in waiting { done(status) }
        }
        let state = manager.state
        if state == .unknown { return }
        if state == .resetting {
            // The system drops every connection without a disconnect
            // callback; scans resume when the radio is back.
            dropLinks(DeviceCallError("disconnected", "bluetooth: the Bluetooth system reset"))
            return
        }
        let waiting = readiness
        readiness = []
        let error = Self.problem(state)
        for done in waiting { done(error) }
        if state == .poweredOn {
            updateScan()
            return
        }
        // Off, or no longer allowed: everything in flight ends. The system
        // drops connections without a disconnect callback.
        let error2 = error ?? DeviceCallError("unavailable", "bluetooth: the radio isn't ready")
        let ended = scans
        scans = []
        for scan in ended { scan.failed(error2) }
        dropLinks(DeviceCallError("disconnected", "bluetooth: \(error2.message)"), connecting: error2)
    }

    /// Ends every connect in flight (with `connecting`, or `error`) and
    /// every connection (with `error`).
    private func dropLinks(_ error: DeviceCallError, connecting connectError: DeviceCallError? = nil) {
        for id in Array(connecting.keys) { connectFailed(id, connectError ?? error) }
        let dropped = connected
        connected = [:]
        releasing = []
        for peripheral in dropped.values { peripheral.dropped(error) }
    }

    public func scan(
        services: [String]?, allowDuplicates: Bool, found: @escaping @MainActor (BluetoothAdvertisement) -> Void,
        failed: @escaping @MainActor (DeviceCallError) -> Void
    ) -> StreamSource {
        let scan = Scan(services: services?.map { CBUUID(string: $0) }, allowDuplicates: allowDuplicates, found: found, failed: failed)
        scan.central = self
        scans.append(scan)
        updateScan()
        return scan
    }

    fileprivate func remove(_ scan: Scan) {
        scans.removeAll { $0 === scan }
        updateScan()
        // Keep only what a connect needs; `retrievePeripherals` finds the
        // rest again.
        if scans.isEmpty { seen = seen.filter { connected[$0.key] != nil || connecting[$0.key] != nil } }
    }

    /// One system scan for every open one: the union of their filters,
    /// duplicates when any wants them. Each filters its own.
    private func updateScan() {
        guard let manager, manager.state == .poweredOn else { return }
        guard !scans.isEmpty else {
            if manager.isScanning { manager.stopScan() }
            return
        }
        let services: [CBUUID]? = scans.contains { $0.services == nil } ? nil : Array(Set(scans.flatMap { $0.services ?? [] }))
        let duplicates = scans.contains { $0.allowDuplicates }
        manager.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: duplicates])
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated { discovered(peripheral, advertisementData, RSSI.intValue) }
    }

    private func discovered(_ peripheral: CBPeripheral, _ data: [String: Any], _ rssi: Int) {
        seen[peripheral.identifier] = peripheral
        // 127: the radio couldn't read it.
        guard rssi != 127 else { return }
        let services = (data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (data[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        var serviceData: [String: Data] = [:]
        for (uuid, value) in data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:] {
            serviceData[uuid.uuidString] = value
        }
        let advertisement = BluetoothAdvertisement(
            id: peripheral.identifier, name: data[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name, rssi: rssi,
            services: services.map(\.uuidString), manufacturerData: data[CBAdvertisementDataManufacturerDataKey] as? Data,
            serviceData: serviceData)
        for scan in scans {
            if let wanted = scan.services, !services.contains(where: wanted.contains) { continue }
            if !scan.allowDuplicates, !scan.heard.insert(peripheral.identifier).inserted { continue }
            scan.found(advertisement)
        }
    }

    public func known(_ ids: [UUID]) -> [BluetoothKnownPeripheral] {
        guard let manager else { return [] }
        return manager.retrievePeripherals(withIdentifiers: ids).map { peripheral in
            seen[peripheral.identifier] = peripheral
            return BluetoothKnownPeripheral(id: peripheral.identifier, name: peripheral.name)
        }
    }

    public func connect(
        _ id: UUID, timeout: TimeInterval, done: @escaping @MainActor (Result<BluetoothPeripheral, DeviceCallError>) -> Void
    ) -> () -> Void {
        guard let manager else {
            done(.failure(DeviceCallError("unavailable", "bluetooth: the radio isn't ready")))
            return {}
        }
        guard connected[id] == nil, connecting[id] == nil else {
            done(.failure(DeviceCallError("failed", "bluetooth.connect: \(id.uuidString) is already connected; close that handle first")))
            return {}
        }
        guard let peripheral = seen[id] ?? manager.retrievePeripherals(withIdentifiers: [id]).first else {
            done(.failure(DeviceCallError("failed", "bluetooth.connect: no peripheral \(id.uuidString) is known; scan for it first")))
            return {}
        }
        seen[id] = peripheral
        let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.connectFailed(id, DeviceCallError("timeout", "bluetooth.connect: \(id.uuidString) didn't answer in \(Int(timeout)) s"))
            }
        }
        connecting[id] = Connecting(peripheral: peripheral, done: done, timer: timer)
        manager.connect(peripheral)
        return { [weak self] in self?.connectFailed(id, nil) }
    }

    /// Ends a connect in flight: with `error`, or quietly for a cancel.
    private func connectFailed(_ id: UUID, _ error: DeviceCallError?) {
        guard let attempt = connecting.removeValue(forKey: id) else { return }
        attempt.timer.invalidate()
        manager?.cancelPeripheralConnection(attempt.peripheral)
        if let error { attempt.done(.failure(error)) }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard let attempt = connecting.removeValue(forKey: peripheral.identifier) else {
                // Cancelled meanwhile.
                central.cancelPeripheralConnection(peripheral)
                return
            }
            attempt.timer.invalidate()
            let wrapper = SystemBluetoothPeripheral(peripheral, central: self)
            connected[peripheral.identifier] = wrapper
            attempt.done(.success(wrapper))
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let reason = error?.localizedDescription ?? "the connection failed"
            connectFailed(peripheral.identifier, DeviceCallError("failed", "bluetooth.connect: \(reason)"))
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            // The callback of a link `disconnect()` let go of: a connect
            // made since is a new link.
            if releasing.remove(id) != nil { return }
            connectFailed(id, DeviceCallError("disconnected", "bluetooth.connect: \(id.uuidString) disconnected"))
            let reason = error.map { ": \($0.localizedDescription)" } ?? ""
            connected.removeValue(forKey: id)?.dropped(DeviceCallError("disconnected", "bluetooth: \(id.uuidString) disconnected\(reason)"))
        }
    }

    /// `disconnect()` on a peripheral: let it go.
    fileprivate func release(_ peripheral: SystemBluetoothPeripheral) {
        guard connected[peripheral.id] === peripheral else { return }
        connected[peripheral.id] = nil
        releasing.insert(peripheral.id)
        manager?.cancelPeripheralConnection(peripheral.peripheral)
    }
}

/// A connected `CBPeripheral`: its delegate, with each call's answer
/// waiting on the callback it needs.
@MainActor
final class SystemBluetoothPeripheral: NSObject, BluetoothPeripheral, CBPeripheralDelegate {
    let peripheral: CBPeripheral
    private weak var central: SystemBluetoothCentral?
    var onDisconnect: (@MainActor (DeviceCallError) -> Void)?
    /// Set once the link dropped or `disconnect()` ran.
    private var ended = false

    private var discovered: [BluetoothServiceInfo]?
    private var discovering = false
    private var characteristicsLeft = 0
    private var discoveryError: DeviceCallError?
    private var serviceWaiters: [Int: @MainActor (Result<Void, DeviceCallError>) -> Void] = [:]
    /// Waiting reads and writes by characteristic, oldest first.
    private var reads: [ObjectIdentifier: [(key: Int, done: @MainActor (Result<Data, DeviceCallError>) -> Void)]] = [:]
    /// Writes with a response sent and not yet confirmed. A cancelled one
    /// stays with no `done`, so its confirmation answers nobody rather
    /// than the next write.
    private var writes: [ObjectIdentifier: [(key: Int, done: (@MainActor (Result<Void, DeviceCallError>) -> Void)?)]] = [:]
    /// Writes without a response waiting for room in Core Bluetooth's
    /// queue, in order.
    private var unsent: [(key: Int, characteristic: CBCharacteristic, data: Data, done: @MainActor (Result<Void, DeviceCallError>) -> Void)] = []
    /// Characteristics this peripheral asked to notify: `isNotifying`
    /// changes only once the peripheral answers.
    private var subscribed: Set<ObjectIdentifier> = []
    private var rssiWaiters: [Int: @MainActor (Result<Int, DeviceCallError>) -> Void] = [:]
    private var notifies: [ObjectIdentifier: [Notify]] = [:]
    private var nextKey = 0

    fileprivate final class Notify: StreamSource {
        let update: @MainActor (Data) -> Void
        let ended: @MainActor (DeviceCallError?) -> Void
        weak var owner: SystemBluetoothPeripheral?
        var characteristic: CBCharacteristic?
        var cancelSetup: (() -> Void)?
        var done = false

        init(update: @escaping @MainActor (Data) -> Void, ended: @escaping @MainActor (DeviceCallError?) -> Void) {
            self.update = update
            self.ended = ended
        }

        func stop() {
            guard !done else { return }
            done = true
            cancelSetup?()
            owner?.remove(self)
        }

        /// The source ends it: no `stop()` follows.
        func end(_ error: DeviceCallError?) {
            guard !done else { return }
            done = true
            ended(error)
        }
    }

    init(_ peripheral: CBPeripheral, central: SystemBluetoothCentral) {
        self.peripheral = peripheral
        self.central = central
        super.init()
        peripheral.delegate = self
    }

    var id: UUID { peripheral.identifier }
    var name: String? { peripheral.name }

    private func key() -> Int {
        nextKey += 1
        return nextKey
    }

    private var closedError: DeviceCallError { DeviceCallError("failed", "bluetooth: the peripheral was closed") }

    // MARK: Discovery

    func services(_ done: @escaping @MainActor (Result<[BluetoothServiceInfo], DeviceCallError>) -> Void) -> () -> Void {
        whenDiscovered { [weak self] result in
            guard let self else { return }
            done(result.map { self.discovered ?? [] })
        }
    }

    /// Runs `done` once services and characteristics are discovered.
    private func whenDiscovered(_ done: @escaping @MainActor (Result<Void, DeviceCallError>) -> Void) -> () -> Void {
        if ended {
            done(.failure(closedError))
            return {}
        }
        if discovered != nil {
            done(.success(()))
            return {}
        }
        let key = key()
        serviceWaiters[key] = done
        if !discovering {
            discovering = true
            discoveryError = nil
            peripheral.discoverServices(nil)
        }
        return { [weak self] in self?.serviceWaiters[key] = nil }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                return finishDiscovery(DeviceCallError("failed", "bluetooth: service discovery failed: \(error.localizedDescription)"))
            }
            let services = peripheral.services ?? []
            characteristicsLeft = services.count
            if services.isEmpty { return finishDiscovery(nil) }
            for service in services { peripheral.discoverCharacteristics(nil, for: service) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            if let error, discoveryError == nil {
                discoveryError = DeviceCallError("failed", "bluetooth: characteristic discovery failed: \(error.localizedDescription)")
            }
            characteristicsLeft -= 1
            if characteristicsLeft <= 0 { finishDiscovery(discoveryError) }
        }
    }

    private func finishDiscovery(_ error: DeviceCallError?) {
        discovering = false
        if error == nil {
            discovered = (peripheral.services ?? []).map { service in
                BluetoothServiceInfo(
                    uuid: service.uuid.uuidString,
                    characteristics: (service.characteristics ?? []).map {
                        BluetoothCharacteristicInfo(uuid: $0.uuid.uuidString, properties: Self.properties($0.properties))
                    })
            }
        }
        let waiting = serviceWaiters.values
        serviceWaiters = [:]
        for done in waiting { done(error.map { .failure($0) } ?? .success(())) }
    }

    static func properties(_ properties: CBCharacteristicProperties) -> [String] {
        var names: [String] = []
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        return names
    }

    /// Runs `body` with the characteristic once discovered, or fails
    /// `failed`. Returns a cancel for both steps.
    private func withCharacteristic(
        _ method: String, _ service: String, _ characteristic: String, failed: @escaping @MainActor (DeviceCallError) -> Void,
        body: @escaping @MainActor (CBCharacteristic) -> (() -> Void)
    ) -> () -> Void {
        var cancelled = false
        var cancelBody: (() -> Void)?
        let cancelDiscovery = whenDiscovered { [weak self] result in
            guard let self, !cancelled else { return }
            if case let .failure(error) = result { return failed(error) }
            let serviceID = CBUUID(string: service)
            let characteristicID = CBUUID(string: characteristic)
            guard let found = self.peripheral.services?.first(where: { $0.uuid == serviceID })?
                .characteristics?.first(where: { $0.uuid == characteristicID })
            else {
                return failed(DeviceCallError("failed", "\(method): no characteristic \(characteristic) in service \(service)"))
            }
            cancelBody = body(found)
        }
        return {
            cancelled = true
            cancelDiscovery()
            cancelBody?()
        }
    }

    // MARK: Read, write, notify, RSSI

    func read(service: String, characteristic: String, done: @escaping @MainActor (Result<Data, DeviceCallError>) -> Void) -> () -> Void {
        withCharacteristic("bluetooth.read", service, characteristic, failed: { done(.failure($0)) }) { [weak self] found in
            guard let self else { return {} }
            guard found.properties.contains(.read) else {
                done(.failure(DeviceCallError("failed", "bluetooth.read: \(characteristic) can't be read")))
                return {}
            }
            let key = self.key()
            let slot = ObjectIdentifier(found)
            self.reads[slot, default: []].append((key, done))
            self.peripheral.readValue(for: found)
            return { [weak self] in self?.reads[slot]?.removeAll { $0.key == key } }
        }
    }

    func write(
        service: String, characteristic: String, data: Data, withResponse: Bool,
        done: @escaping @MainActor (Result<Void, DeviceCallError>) -> Void
    ) -> () -> Void {
        withCharacteristic("bluetooth.write", service, characteristic, failed: { done(.failure($0)) }) { [weak self] found in
            guard let self else { return {} }
            let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
            guard found.properties.contains(withResponse ? .write : .writeWithoutResponse) else {
                let how = withResponse ? "with a response" : "without a response"
                done(.failure(DeviceCallError("failed", "bluetooth.write: \(characteristic) can't be written \(how)")))
                return {}
            }
            let limit = self.peripheral.maximumWriteValueLength(for: type)
            guard data.count <= limit else {
                done(.failure(DeviceCallError("failed", "bluetooth.write: at most \(limit) bytes at once; this is \(data.count)")))
                return {}
            }
            let key = self.key()
            guard withResponse else {
                // Core Bluetooth drops a write without a response when its
                // queue is full: wait for room, in order.
                self.unsent.append((key, found, data, done))
                self.sendUnsent()
                return { [weak self] in self?.unsent.removeAll { $0.key == key } }
            }
            self.peripheral.writeValue(data, for: found, type: type)
            let slot = ObjectIdentifier(found)
            self.writes[slot, default: []].append((key, done))
            return { [weak self] in
                guard let self, let i = self.writes[slot]?.firstIndex(where: { $0.key == key }) else { return }
                self.writes[slot]?[i].done = nil
            }
        }
    }

    /// Sends the waiting writes without a response while there is room.
    private func sendUnsent() {
        while !ended, let next = unsent.first, peripheral.canSendWriteWithoutResponse {
            unsent.removeFirst()
            peripheral.writeValue(next.data, for: next.characteristic, type: .withoutResponse)
            next.done(.success(()))
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { sendUnsent() }
    }

    func notify(
        service: String, characteristic: String, update: @escaping @MainActor (Data) -> Void,
        ended: @escaping @MainActor (DeviceCallError?) -> Void
    ) -> StreamSource {
        let notify = Notify(update: update, ended: ended)
        notify.owner = self
        notify.cancelSetup = withCharacteristic("bluetooth.notify", service, characteristic, failed: { notify.end($0) }) { [weak self] found in
            guard let self, !notify.done else { return {} }
            guard found.properties.contains(.notify) || found.properties.contains(.indicate) else {
                notify.end(DeviceCallError("failed", "bluetooth.notify: \(characteristic) doesn't notify"))
                return {}
            }
            notify.characteristic = found
            self.notifies[ObjectIdentifier(found), default: []].append(notify)
            if self.subscribed.insert(ObjectIdentifier(found)).inserted { self.peripheral.setNotifyValue(true, for: found) }
            return {}
        }
        return notify
    }

    fileprivate func remove(_ notify: Notify) {
        guard let found = notify.characteristic else { return }
        let slot = ObjectIdentifier(found)
        notifies[slot]?.removeAll { $0 === notify }
        if notifies[slot]?.isEmpty ?? true {
            notifies[slot] = nil
            if subscribed.remove(slot) != nil, !ended { peripheral.setNotifyValue(false, for: found) }
        }
    }

    func rssi(_ done: @escaping @MainActor (Result<Int, DeviceCallError>) -> Void) -> () -> Void {
        if ended {
            done(.failure(closedError))
            return {}
        }
        let key = key()
        rssiWaiters[key] = done
        if rssiWaiters.count == 1 { peripheral.readRSSI() }
        return { [weak self] in self?.rssiWaiters[key] = nil }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            let slot = ObjectIdentifier(characteristic)
            let waiting = reads.removeValue(forKey: slot) ?? []
            let value = characteristic.value ?? Data()
            for read in waiting {
                if let error {
                    read.done(.failure(DeviceCallError("failed", "bluetooth.read: \(error.localizedDescription)")))
                } else {
                    read.done(.success(value))
                }
            }
            guard error == nil, subscribed.contains(slot) else { return }
            for notify in notifies[slot] ?? [] { notify.update(value) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            let slot = ObjectIdentifier(characteristic)
            guard var waiting = writes[slot], !waiting.isEmpty else { return }
            // Confirmations come in the order the writes went out.
            let first = waiting.removeFirst()
            writes[slot] = waiting.isEmpty ? nil : waiting
            if let error {
                first.done?(.failure(DeviceCallError("failed", "bluetooth.write: \(error.localizedDescription)")))
            } else {
                first.done?(.success(()))
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // The GATT table changed: discover again on the next call.
        MainActor.assumeIsolated { if !discovering { discovered = nil } }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let error else { return }
            // A failed unsubscribe leaves nobody to tell.
            guard subscribed.remove(ObjectIdentifier(characteristic)) != nil else { return }
            let failed = notifies.removeValue(forKey: ObjectIdentifier(characteristic)) ?? []
            for notify in failed { notify.end(DeviceCallError("failed", "bluetooth.notify: \(error.localizedDescription)")) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated {
            let waiting = rssiWaiters.values
            rssiWaiters = [:]
            for done in waiting {
                if let error {
                    done(.failure(DeviceCallError("failed", "bluetooth.rssi: \(error.localizedDescription)")))
                } else {
                    done(.success(RSSI.intValue))
                }
            }
        }
    }

    // MARK: Ending

    /// The link dropped: everything waiting fails with `error`.
    fileprivate func dropped(_ error: DeviceCallError) {
        guard !ended else { return }
        end(error, notifyError: error)
        onDisconnect?(error)
        onDisconnect = nil
    }

    func disconnect() {
        guard !ended else { return }
        onDisconnect = nil
        end(closedError, notifyError: nil)
        central?.release(self)
    }

    private func end(_ error: DeviceCallError, notifyError: DeviceCallError?) {
        ended = true
        let services = serviceWaiters.values
        let reads = self.reads.values.flatMap { $0 }
        let writes = self.writes.values.flatMap { $0 }.compactMap { $0.done } + unsent.map { $0.done }
        let rssis = rssiWaiters.values
        let notifies = self.notifies.values.flatMap { $0 }
        serviceWaiters = [:]
        self.reads = [:]
        self.writes = [:]
        unsent = []
        subscribed = []
        rssiWaiters = [:]
        self.notifies = [:]
        for done in services { done(.failure(error)) }
        for read in reads { read.done(.failure(error)) }
        for done in writes { done(.failure(error)) }
        for done in rssis { done(.failure(error)) }
        for notify in notifies { notify.end(notifyError) }
    }
}
