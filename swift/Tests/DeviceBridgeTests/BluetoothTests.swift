@testable import DeviceBridge
import XCTest

/// A peripheral in memory: answers the test sets, and records what was asked.
@MainActor
private final class FakePeripheral: BluetoothPeripheral {
    final class FakeNotify: StreamSource {
        let update: @MainActor (Data) -> Void
        let ended: @MainActor (DeviceCallError?) -> Void
        var stops = 0

        init(update: @escaping @MainActor (Data) -> Void, ended: @escaping @MainActor (DeviceCallError?) -> Void) {
            self.update = update
            self.ended = ended
        }

        func stop() { stops += 1 }
    }

    let id: UUID
    let name: String?
    var onDisconnect: (@MainActor (DeviceCallError) -> Void)?
    var disconnects = 0
    var serviceList: [BluetoothServiceInfo] = []
    /// What `read` answers; nil holds it until the link drops.
    var value: Data?
    var written: [(String, String, Data, Bool)] = []
    var notifies: [FakeNotify] = []
    private var waiting: [@MainActor (DeviceCallError) -> Void] = []

    init(id: UUID, name: String?) {
        self.id = id
        self.name = name
    }

    func services(_ done: @escaping @MainActor (Result<[BluetoothServiceInfo], DeviceCallError>) -> Void) -> () -> Void {
        done(.success(serviceList))
        return {}
    }

    func read(service: String, characteristic: String, done: @escaping @MainActor (Result<Data, DeviceCallError>) -> Void) -> () -> Void {
        if let value {
            done(.success(value))
        } else {
            waiting.append { done(.failure($0)) }
        }
        return {}
    }

    func write(
        service: String, characteristic: String, data: Data, withResponse: Bool,
        done: @escaping @MainActor (Result<Void, DeviceCallError>) -> Void
    ) -> () -> Void {
        written.append((service, characteristic, data, withResponse))
        done(.success(()))
        return {}
    }

    func notify(
        service: String, characteristic: String, update: @escaping @MainActor (Data) -> Void,
        ended: @escaping @MainActor (DeviceCallError?) -> Void
    ) -> StreamSource {
        let notify = FakeNotify(update: update, ended: ended)
        notifies.append(notify)
        return notify
    }

    func rssi(_ done: @escaping @MainActor (Result<Int, DeviceCallError>) -> Void) -> () -> Void {
        done(.success(-60))
        return {}
    }

    func disconnect() {
        disconnects += 1
        for notify in notifies { notify.ended(nil) }
        notifies = []
    }

    /// The peer went away, as `SystemBluetoothPeripheral.dropped` does.
    func drop() {
        let error = DeviceCallError("disconnected", "gone")
        for fail in waiting { fail(error) }
        waiting = []
        for notify in notifies { notify.ended(error) }
        notifies = []
        onDisconnect?(error)
    }
}

/// A central in memory.
@MainActor
private final class FakeCentral: BluetoothCentral {
    final class FakeScan: StreamSource {
        let services: [String]?
        let allowDuplicates: Bool
        let found: @MainActor (BluetoothAdvertisement) -> Void
        var stops = 0

        init(services: [String]?, allowDuplicates: Bool, found: @escaping @MainActor (BluetoothAdvertisement) -> Void) {
            self.services = services
            self.allowDuplicates = allowDuplicates
            self.found = found
        }

        func stop() { stops += 1 }
    }

    var status: PermissionStatus
    var radio: DeviceCallError?
    /// While true, `ready` waits until `powerOn()`.
    var radioPending = false
    var scans: [FakeScan] = []
    var peripherals: [UUID: FakePeripheral] = [:]
    /// While true, `connect` waits until the test calls `finishConnect`.
    var holdConnect = false
    var connectCancels = 0
    var timeouts: [TimeInterval] = []
    private var pendingReady: [@MainActor (DeviceCallError?) -> Void] = []
    private var pendingConnect: (() -> Void)?

    init(_ status: PermissionStatus) {
        self.status = status
    }

    func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) {
        if status == .notDetermined { status = .authorized }
        done(status)
    }

    func ready(_ done: @escaping @MainActor (DeviceCallError?) -> Void) {
        if radioPending {
            pendingReady.append(done)
        } else {
            done(radio)
        }
    }

    func powerOn() {
        radioPending = false
        let waiting = pendingReady
        pendingReady = []
        for done in waiting { done(nil) }
    }

    func scan(
        services: [String]?, allowDuplicates: Bool, found: @escaping @MainActor (BluetoothAdvertisement) -> Void,
        failed: @escaping @MainActor (DeviceCallError) -> Void
    ) -> StreamSource {
        let scan = FakeScan(services: services, allowDuplicates: allowDuplicates, found: found)
        scans.append(scan)
        return scan
    }

    func known(_ ids: [UUID]) -> [BluetoothKnownPeripheral] {
        ids.compactMap { peripherals[$0].map { BluetoothKnownPeripheral(id: $0.id, name: $0.name) } }
    }

    func connect(
        _ id: UUID, timeout: TimeInterval, done: @escaping @MainActor (Result<BluetoothPeripheral, DeviceCallError>) -> Void
    ) -> () -> Void {
        timeouts.append(timeout)
        guard let peripheral = peripherals[id] else {
            done(.failure(DeviceCallError("failed", "no such peripheral")))
            return {}
        }
        if holdConnect {
            pendingConnect = { done(.success(peripheral)) }
        } else {
            done(.success(peripheral))
        }
        return { [weak self] in
            self?.connectCancels += 1
            self?.pendingConnect = nil
        }
    }

    func finishConnect() {
        pendingConnect?()
        pendingConnect = nil
    }
}

/// The ledger's prompt, answering "always".
@MainActor
private final class Always: LedgerPrompter {
    func askPermission(_ capability: String, notebook: String, id: Int, answer: @escaping @MainActor (LedgerAnswer?) -> Void) {
        answer(.always)
    }

    func dismissPermission(_ id: Int) {}
}

@MainActor
final class BluetoothTests: XCTestCase {
    private lazy var always = Always()
    private var nextID = 0
    private let heart = UUID(uuidString: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")!

    /// A bridge with Bluetooth; kernels 1 and 2 run notebooks.
    private func bridge(_ central: FakeCentral) -> DeviceBridge {
        let bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.ledgerPrompter = always
        bridge.setNotebook("a.ipynb", for: 1)
        bridge.setNotebook("b.ipynb", for: 2)
        bridge.addBluetooth(central)
        return bridge
    }

    private func central(_ status: PermissionStatus = .authorized) -> FakeCentral {
        let central = FakeCentral(status)
        central.peripherals[heart] = FakePeripheral(id: heart, name: "Strap")
        return central
    }

    private func call(_ bridge: DeviceBridge, _ method: String, _ params: [String: Any] = [:], owner: Int = 1, id: Int? = nil) -> [String: Any]? {
        nextID += 1
        var answer: [String: Any]?
        bridge.respond(to: ["id": id ?? nextID, "owner": owner, "method": method, "params": params]) { answer = $0 }
        return answer
    }

    private func errorCode(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["code"] as? String
    }

    private func connect(_ bridge: DeviceBridge, owner: Int = 1) throws -> Int {
        let reply = try XCTUnwrap(call(bridge, "bluetooth.connect", ["id": heart.uuidString], owner: owner)?["result"] as? [String: Any])
        XCTAssertEqual(reply["id"] as? String, heart.uuidString)
        XCTAssertEqual(reply["name"] as? String, "Strap")
        return try XCTUnwrap(reply["peripheral"] as? Int)
    }

    func testHelloListsTheNamespace() {
        let capabilities = bridge(central()).capabilities
        for method in [
            "bluetooth.authorizationStatus", "bluetooth.requestAuthorization", "bluetooth.scan", "bluetooth.known",
            "bluetooth.connect", "bluetooth.services", "bluetooth.read", "bluetooth.write", "bluetooth.notify", "bluetooth.rssi",
        ] {
            XCTAssertTrue(capabilities.contains(method), method)
        }
    }

    func testScanAsksThenStreamsAdvertisements() throws {
        let central = central(.notDetermined)
        let bridge = bridge(central)
        let started = call(bridge, "bluetooth.scan", ["services": ["180d"], "allowDuplicates": true], id: 7)
        XCTAssertEqual((started?["result"] as? [String: Any])?["stream"] as? Int, 7)
        XCTAssertEqual(central.status, .authorized)
        let scan = try XCTUnwrap(central.scans.first)
        XCTAssertEqual(scan.services, ["180D"])
        XCTAssertTrue(scan.allowDuplicates)
        scan.found(BluetoothAdvertisement(
            id: heart, name: nil, rssi: -50, services: ["180D"], manufacturerData: Data([1, 2]), serviceData: ["180D": Data([3])]))
        let batch = try XCTUnwrap(call(bridge, "stream.next", ["stream": 7])?["result"] as? [String: Any])
        let ad = try XCTUnwrap((batch["values"] as? [[String: Any]])?.first)
        XCTAssertEqual(ad["id"] as? String, heart.uuidString)
        XCTAssertTrue(ad["name"] is NSNull)
        XCTAssertEqual(ad["rssi"] as? Int, -50)
        XCTAssertEqual(ad["services"] as? [String], ["180D"])
        XCTAssertEqual((ad["manufacturerData"] as? [String: Any])?["base64"] as? String, "AQI=")
        XCTAssertEqual(((ad["serviceData"] as? [String: Any])?["180D"] as? [String: Any])?["base64"] as? String, "Aw==")
        _ = call(bridge, "stream.close", ["stream": 7])
        XCTAssertEqual(scan.stops, 1)
    }

    func testScanRefusesBadArgumentsBeforeAsking() {
        let central = central(.notDetermined)
        let bridge = bridge(central)
        XCTAssertEqual(errorCode(call(bridge, "bluetooth.scan", ["services": ["heart"]])), "failed")
        XCTAssertEqual(errorCode(call(bridge, "bluetooth.scan", ["allowDuplicates": 1])), "failed")
        XCTAssertEqual(central.status, .notDetermined)
        XCTAssertTrue(central.scans.isEmpty)
    }

    func testRadioOffFailsUnavailable() {
        let central = central()
        central.radio = DeviceCallError("unavailable", "Bluetooth is off")
        let bridge = bridge(central)
        XCTAssertEqual(errorCode(call(bridge, "bluetooth.connect", ["id": heart.uuidString])), "unavailable")
        XCTAssertEqual(errorCode(call(bridge, "bluetooth.known", ["ids": [heart.uuidString]])), "unavailable")
        _ = call(bridge, "bluetooth.scan", [:], id: 9)
        XCTAssertEqual(errorCode(call(bridge, "stream.next", ["stream": 9])), "unavailable")
        XCTAssertTrue(central.scans.isEmpty)
    }

    func testScanStoppedWhileTheRadioWaitsNeverStarts() {
        let central = central()
        central.radioPending = true
        let bridge = bridge(central)
        _ = call(bridge, "bluetooth.scan", [:], id: 5)
        _ = call(bridge, "stream.close", ["stream": 5])
        central.powerOn()
        XCTAssertTrue(central.scans.isEmpty)
    }

    func testKnownResolvesIds() throws {
        let bridge = bridge(central())
        let other = UUID()
        let list = try XCTUnwrap(call(bridge, "bluetooth.known", ["ids": [heart.uuidString, other.uuidString]])?["result"] as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?["id"] as? String, heart.uuidString)
        XCTAssertEqual(errorCode(call(bridge, "bluetooth.known", ["ids": ["nope"]])), "failed")
    }

    func testConnectOpensAHandleTheKernelUses() throws {
        let central = central()
        let bridge = bridge(central)
        let fake = try XCTUnwrap(central.peripherals[heart])
        fake.serviceList = [BluetoothServiceInfo(uuid: "180D", characteristics: [BluetoothCharacteristicInfo(uuid: "2A37", properties: ["notify"])])]
        fake.value = Data([0x2A])
        let handle = try connect(bridge)
        XCTAssertEqual(central.timeouts, [BluetoothHub.defaultTimeout])
        XCTAssertTrue(bridge.handles.isOpen(handle, owner: 1, kind: BluetoothHub.kind))

        let services = try XCTUnwrap(call(bridge, "bluetooth.services", ["peripheral": handle])?["result"] as? [[String: Any]])
        XCTAssertEqual(services.first?["uuid"] as? String, "180D")
        let chars = try XCTUnwrap(services.first?["characteristics"] as? [[String: Any]])
        XCTAssertEqual(chars.first?["properties"] as? [String], ["notify"])

        let read = call(bridge, "bluetooth.read", ["peripheral": handle, "service": "180d", "characteristic": "2a37"])
        XCTAssertEqual((read?["result"] as? [String: Any])?["base64"] as? String, "Kg==")

        let wrote = call(bridge, "bluetooth.write", [
            "peripheral": handle, "service": "180D", "characteristic": "2A39", "data": ["base64": "AQ=="], "withResponse": false,
        ])
        XCTAssertTrue(wrote?["result"] is NSNull)
        XCTAssertEqual(fake.written.first?.0, "180D")
        XCTAssertEqual(fake.written.first?.2, Data([1]))
        XCTAssertEqual(fake.written.first?.3, false)

        XCTAssertEqual(call(bridge, "bluetooth.rssi", ["peripheral": handle])?["result"] as? Int, -60)

        // Another kernel can't reach it.
        XCTAssertEqual(errorCode(call(bridge, "bluetooth.read", ["peripheral": handle, "service": "180D", "characteristic": "2A37"], owner: 2)), "failed")
        // A bad UUID fails before reaching the peripheral.
        XCTAssertEqual(errorCode(call(bridge, "bluetooth.read", ["peripheral": handle, "service": "x", "characteristic": "2A37"])), "failed")

        _ = bridge.handle(["owner": 1, "method": "handle.close", "params": ["handle": handle]])
        XCTAssertEqual(fake.disconnects, 1)
        XCTAssertEqual(errorCode(call(bridge, "bluetooth.rssi", ["peripheral": handle])), "failed")
    }

    func testNotifyStreamsValuesAndEndsOnClose() throws {
        let central = central()
        let bridge = bridge(central)
        let fake = try XCTUnwrap(central.peripherals[heart])
        let handle = try connect(bridge)
        let started = bridge.handle([
            "id": 30, "owner": 1, "method": "bluetooth.notify",
            "params": ["peripheral": handle, "service": "180D", "characteristic": "2A37"],
        ])
        XCTAssertEqual((started["result"] as? [String: Any])?["stream"] as? Int, 30)
        // Another kernel's notify on the handle is refused.
        let refused = bridge.handle([
            "id": 31, "owner": 2, "method": "bluetooth.notify",
            "params": ["peripheral": handle, "service": "180D", "characteristic": "2A37"],
        ])
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? String, "failed")
        let notify = try XCTUnwrap(fake.notifies.first)
        notify.update(Data([9]))
        let batch = try XCTUnwrap(call(bridge, "stream.next", ["stream": 30])?["result"] as? [String: Any])
        XCTAssertEqual((batch["values"] as? [[String: Any]])?.first?["base64"] as? String, "CQ==")
        _ = bridge.handle(["owner": 1, "method": "handle.close", "params": ["handle": handle]])
        let end = try XCTUnwrap(call(bridge, "stream.next", ["stream": 30])?["result"] as? [String: Any])
        XCTAssertEqual(end["end"] as? Bool, true)
    }

    func testPeerDropRejectsDisconnectedAndClosesTheHandle() throws {
        let central = central()
        let bridge = bridge(central)
        let fake = try XCTUnwrap(central.peripherals[heart])
        let handle = try connect(bridge)
        _ = bridge.handle([
            "id": 40, "owner": 1, "method": "bluetooth.notify",
            "params": ["peripheral": handle, "service": "180D", "characteristic": "2A37"],
        ])
        var pending: [String: Any]?
        bridge.respond(to: [
            "id": 41, "owner": 1, "method": "bluetooth.read",
            "params": ["peripheral": handle, "service": "180D", "characteristic": "2A37"],
        ]) { pending = $0 }
        XCTAssertNil(pending)
        fake.drop()
        XCTAssertEqual(errorCode(pending), "disconnected")
        XCTAssertEqual(errorCode(call(bridge, "stream.next", ["stream": 40])), "disconnected")
        XCTAssertFalse(bridge.handles.isOpen(handle, owner: 1, kind: BluetoothHub.kind))
        // Dropped, so closing it doesn't disconnect again.
        XCTAssertEqual(fake.disconnects, 0)
        // A later call says why, to its kernel only.
        XCTAssertEqual(errorCode(call(bridge, "bluetooth.rssi", ["peripheral": handle])), "disconnected")
        XCTAssertEqual(errorCode(call(bridge, "bluetooth.rssi", ["peripheral": handle], owner: 2)), "failed")
    }

    func testCancelCrossingTheReplyClosesTheHandle() throws {
        let central = central()
        let bridge = bridge(central)
        let reply = try XCTUnwrap(call(bridge, "bluetooth.connect", ["id": heart.uuidString], id: 60)?["result"] as? [String: Any])
        let handle = try XCTUnwrap(reply["peripheral"] as? Int)
        // The page cancelled before the answer reached it.
        _ = bridge.handle(["id": 60, "owner": 1, "cancel": true])
        XCTAssertFalse(bridge.handles.isOpen(handle, owner: 1, kind: BluetoothHub.kind))
        XCTAssertEqual(central.peripherals[heart]?.disconnects, 1)
    }

    func testCancelDuringConnectStopsIt() {
        let central = central()
        central.holdConnect = true
        let bridge = bridge(central)
        var answer: [String: Any]?
        bridge.respond(to: ["id": 50, "owner": 1, "method": "bluetooth.connect", "params": ["id": heart.uuidString, "timeout": 5]]) { answer = $0 }
        XCTAssertEqual(central.timeouts, [5])
        _ = bridge.handle(["id": 50, "owner": 1, "cancel": true])
        XCTAssertEqual(errorCode(answer), "cancelled")
        XCTAssertEqual(central.connectCancels, 1)
        XCTAssertEqual(bridge.handles.count(owner: 1, kind: BluetoothHub.kind), 0)
    }

    func testReleaseDisconnectsAndTheLimitHolds() throws {
        let central = central()
        let bridge = bridge(central)
        for _ in 0..<BluetoothHub.maxPeripherals {
            _ = try connect(bridge)
        }
        XCTAssertEqual(errorCode(call(bridge, "bluetooth.connect", ["id": heart.uuidString])), "failed")
        XCTAssertEqual(errorCode(call(bridge, "bluetooth.connect", ["id": heart.uuidString, "timeout": 0])), "failed")
        _ = bridge.handle(["owner": 1, "release": true])
        XCTAssertEqual(central.peripherals[heart]?.disconnects, BluetoothHub.maxPeripherals)
        XCTAssertEqual(bridge.handles.count(owner: 1, kind: BluetoothHub.kind), 0)
    }

    func testUUIDs() throws {
        XCTAssertEqual(try BluetoothHub.uuid("m", "180d"), "180D")
        XCTAssertEqual(try BluetoothHub.uuid("m", "0000180d"), "0000180D")
        XCTAssertEqual(try BluetoothHub.uuid("m", heart.uuidString.lowercased()), heart.uuidString)
        XCTAssertThrowsError(try BluetoothHub.uuid("m", "18"))
        XCTAssertThrowsError(try BluetoothHub.uuid("m", "zzzz"))
    }
}
