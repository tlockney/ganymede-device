import CoreLocation
@testable import DeviceBridge
import XCTest

/// A location provider in memory: fixes and places the test hands out.
@MainActor
private final class FakeLocation: LocationProvider {
    final class FakeWatch: StreamSource {
        let accuracy: LocationAccuracy
        let update: @MainActor (CLLocation) -> Void
        let failed: @MainActor (DeviceCallError) -> Void
        var stops = 0

        init(_ accuracy: LocationAccuracy, update: @escaping @MainActor (CLLocation) -> Void, failed: @escaping @MainActor (DeviceCallError) -> Void) {
            self.accuracy = accuracy
            self.update = update
            self.failed = failed
        }

        func stop() { stops += 1 }
    }

    var status: PermissionStatus
    var answer: PermissionStatus = .authorized
    var prompts = 0
    /// What `current` answers; nil holds the call until cancelled.
    var fix: Result<CLLocation, DeviceCallError>?
    var asked: [LocationAccuracy] = []
    var cancels = 0
    var watches: [FakeWatch] = []
    var places: [GeoPlace] = []
    var geocoded: [String] = []
    var reversed: [[Double]] = []

    init(_ status: PermissionStatus) {
        self.status = status
    }

    func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) {
        if status == .notDetermined {
            prompts += 1
            status = answer
        }
        done(status)
    }

    func current(_ accuracy: LocationAccuracy, done: @escaping @MainActor (Result<CLLocation, DeviceCallError>) -> Void) -> () -> Void {
        asked.append(accuracy)
        if let fix { done(fix) }
        return { [weak self] in self?.cancels += 1 }
    }

    func watch(
        _ accuracy: LocationAccuracy, update: @escaping @MainActor (CLLocation) -> Void,
        failed: @escaping @MainActor (DeviceCallError) -> Void
    ) -> StreamSource {
        let watch = FakeWatch(accuracy, update: update, failed: failed)
        watches.append(watch)
        return watch
    }

    func geocode(_ address: String, done: @escaping @MainActor (Result<[GeoPlace], DeviceCallError>) -> Void) -> () -> Void {
        geocoded.append(address)
        done(.success(places))
        return {}
    }

    func reverseGeocode(
        latitude: Double, longitude: Double, done: @escaping @MainActor (Result<[GeoPlace], DeviceCallError>) -> Void
    ) -> () -> Void {
        reversed.append([latitude, longitude])
        done(.success(places))
        return {}
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
final class LocationTests: XCTestCase {
    private lazy var always = Always()
    private var nextID = 0

    private let paris = CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35), altitude: 35,
        horizontalAccuracy: 5, verticalAccuracy: 3, course: -1, speed: 1.5,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000))

    /// A bridge with location; kernel 1 runs a.ipynb, kernel 2 none.
    private func bridge(_ provider: FakeLocation) -> DeviceBridge {
        let bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.ledgerPrompter = always
        bridge.setNotebook("a.ipynb", for: 1)
        bridge.addLocation(provider)
        return bridge
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

    func testHelloListsTheNamespace() {
        let capabilities = bridge(FakeLocation(.authorized)).capabilities
        for method in [
            "location.authorizationStatus", "location.requestAuthorization", "location.current",
            "location.watch", "location.geocode", "location.reverseGeocode",
        ] {
            XCTAssertTrue(capabilities.contains(method), method)
        }
        let bare = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        XCTAssertFalse(bare.capabilities.contains { $0.hasPrefix("location.") })
    }

    func testCurrentAsksThenAnswersTheFix() throws {
        let provider = FakeLocation(.notDetermined)
        provider.fix = .success(paris)
        let reply = call(bridge(provider), "location.current", ["accuracy": "city"])
        let fix = try XCTUnwrap(reply?["result"] as? [String: Any])
        XCTAssertEqual(provider.prompts, 1)
        XCTAssertEqual(provider.asked, [.city])
        XCTAssertEqual(fix["latitude"] as? Double, 48.85)
        XCTAssertEqual(fix["longitude"] as? Double, 2.35)
        XCTAssertEqual(fix["accuracy"] as? Double, 5)
        XCTAssertEqual(fix["altitude"] as? Double, 35)
        XCTAssertEqual(fix["altitudeAccuracy"] as? Double, 3)
        XCTAssertEqual(fix["speed"] as? Double, 1.5)
        XCTAssertNil(fix["course"], "an unknown course is left out")
        XCTAssertEqual(fix["timestamp"] as? Double, 1_700_000_000_000)
    }

    func testDefaultsToBestAndRejectsAnUnknownAccuracy() {
        let provider = FakeLocation(.authorized)
        provider.fix = .success(paris)
        let bridge = bridge(provider)
        XCTAssertNotNil(call(bridge, "location.current")?["result"])
        XCTAssertEqual(errorCode(call(bridge, "location.current", ["accuracy": "street"])), "failed")
        XCTAssertEqual(provider.asked, [.best])
    }

    func testABadAccuracyFailsBeforeAnyPrompt() {
        let provider = FakeLocation(.notDetermined)
        let bridge = bridge(provider)
        XCTAssertEqual(errorCode(call(bridge, "location.current", ["accuracy": 3])), "failed")
        XCTAssertEqual(errorCode(call(bridge, "location.watch", ["accuracy": "street"])), "failed")
        XCTAssertEqual(provider.prompts, 0, "the system prompt never showed")
        XCTAssertEqual(provider.status, .notDetermined)
    }

    func testAnAltitudeKnownExactlyIsKept() {
        let exact = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2), altitude: 10,
            horizontalAccuracy: 5, verticalAccuracy: 0, timestamp: Date())
        XCTAssertEqual(DeviceBridge.fixReply(exact)["altitude"] as? Double, 10)
        let unknown = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2), altitude: 10,
            horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: Date())
        XCTAssertNil(DeviceBridge.fixReply(unknown)["altitude"])
    }

    func testRefusalsRejectDenied() {
        let provider = FakeLocation(.notDetermined)
        provider.answer = .denied
        provider.fix = .success(paris)
        let bridge = bridge(provider)
        XCTAssertEqual(errorCode(call(bridge, "location.current")), "denied")
        XCTAssertEqual(errorCode(call(bridge, "location.current", owner: 2)), "denied", "no notebook")
        XCTAssertTrue(provider.asked.isEmpty)
    }

    func testReducedAccuracyReadsAsSuchAndStillAnswers() {
        let provider = FakeLocation(.reducedAccuracy)
        provider.fix = .success(paris)
        let bridge = bridge(provider)
        XCTAssertEqual(call(bridge, "location.authorizationStatus")?["result"] as? String, "reducedAccuracy")
        XCTAssertNotNil(call(bridge, "location.current")?["result"])
    }

    func testAFailedFixAnswersItsCode() {
        let provider = FakeLocation(.authorized)
        provider.fix = .failure(DeviceCallError("failed", "no fix"))
        XCTAssertEqual(errorCode(call(bridge(provider), "location.current")), "failed")
    }

    func testCancellingCurrentStopsTheSearch() {
        let provider = FakeLocation(.authorized)
        let bridge = bridge(provider)
        var answer: [String: Any]?
        bridge.respond(to: ["id": 7, "owner": 1, "method": "location.current", "params": [:]]) { answer = $0 }
        XCTAssertNil(answer)
        _ = bridge.handle(["id": 7, "cancel": true])
        XCTAssertEqual(provider.cancels, 1)
        XCTAssertEqual(errorCode(answer), "cancelled")
    }

    func testWatchStreamsFixesUntilClosed() throws {
        let provider = FakeLocation(.authorized)
        let bridge = bridge(provider)
        let opened = call(bridge, "location.watch", ["accuracy": "block"], id: 1)
        let stream = try XCTUnwrap((opened?["result"] as? [String: Any])?["stream"] as? Int)
        let watch = try XCTUnwrap(provider.watches.first)
        XCTAssertEqual(watch.accuracy, .block)
        watch.update(paris)
        let next = call(bridge, "stream.next", ["stream": stream])
        let values = try XCTUnwrap((next?["result"] as? [String: Any])?["values"] as? [[String: Any]])
        XCTAssertEqual(values.first?["latitude"] as? Double, 48.85)

        _ = call(bridge, "stream.close", ["stream": stream])
        XCTAssertEqual(watch.stops, 1)
    }

    func testAWatchThatFailsEndsWithTheError() throws {
        let provider = FakeLocation(.authorized)
        let bridge = bridge(provider)
        let opened = call(bridge, "location.watch", id: 1)
        let stream = try XCTUnwrap((opened?["result"] as? [String: Any])?["stream"] as? Int)
        provider.watches[0].failed(DeviceCallError("denied", "turned off"))
        XCTAssertEqual(errorCode(call(bridge, "stream.next", ["stream": stream])), "denied")
    }

    func testAReleaseStopsTheWatch() throws {
        let provider = FakeLocation(.authorized)
        let bridge = bridge(provider)
        _ = call(bridge, "location.watch", id: 1)
        bridge.dropPage()
        XCTAssertEqual(provider.watches.first?.stops, 1)
    }

    func testWatchNeedsThePermission() {
        let provider = FakeLocation(.denied)
        XCTAssertEqual(errorCode(call(bridge(provider), "location.watch")), "denied")
        XCTAssertTrue(provider.watches.isEmpty)
    }

    func testGeocodingNeedsNoPermissionAndAnswersPlaces() throws {
        let provider = FakeLocation(.denied)
        provider.places = [GeoPlace(name: "Eiffel Tower", street: "", city: "Paris", countryCode: "FR", latitude: 48.86, longitude: 2.29)]
        let bridge = bridge(provider)
        let found = try XCTUnwrap(call(bridge, "location.geocode", ["address": "Champ de Mars"])?["result"] as? [[String: Any]])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0]["name"] as? String, "Eiffel Tower")
        XCTAssertEqual(found[0]["city"] as? String, "Paris")
        XCTAssertNil(found[0]["street"], "empty parts are left out")
        XCTAssertEqual(found[0]["latitude"] as? Double, 48.86)
        XCTAssertNotNil(call(bridge, "location.reverseGeocode", ["latitude": 48.85, "longitude": 2.35], owner: 2)?["result"])
        XCTAssertEqual(provider.geocoded, ["Champ de Mars"])
        XCTAssertEqual(provider.reversed, [[48.85, 2.35]])
    }

    func testGeocodingChecksItsArguments() {
        let provider = FakeLocation(.authorized)
        let bridge = bridge(provider)
        XCTAssertEqual(errorCode(call(bridge, "location.geocode", ["address": " "])), "failed")
        XCTAssertEqual(errorCode(call(bridge, "location.reverseGeocode", ["latitude": 91, "longitude": 0])), "failed")
        XCTAssertEqual(errorCode(call(bridge, "location.reverseGeocode", ["latitude": 0])), "failed")
        XCTAssertTrue(provider.geocoded.isEmpty && provider.reversed.isEmpty)
    }

    func testCoreLocationStatusesMap() {
        XCTAssertEqual(SystemLocationProvider.status(.notDetermined, .fullAccuracy), .notDetermined)
        XCTAssertEqual(SystemLocationProvider.status(.denied, .fullAccuracy), .denied)
        XCTAssertEqual(SystemLocationProvider.status(.restricted, .fullAccuracy), .restricted)
        XCTAssertEqual(SystemLocationProvider.status(.authorizedAlways, .fullAccuracy), .authorized)
        XCTAssertEqual(SystemLocationProvider.status(.authorizedAlways, .reducedAccuracy), .reducedAccuracy)
    }
}
