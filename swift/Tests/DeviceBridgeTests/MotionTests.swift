@testable import DeviceBridge
import XCTest

/// Motion sensors in memory: the test sends samples, and sees the interval.
@MainActor
private final class FakeMotion: MotionProvider {
    var isAvailable = true
    var intervals: [TimeInterval] = []
    var stops = 0
    var handler: (@MainActor (MotionSample) -> Void)?
    var running: Bool { handler != nil }

    func start(interval: TimeInterval, handler: @escaping @MainActor (MotionSample) -> Void) {
        intervals.append(interval)
        self.handler = handler
    }

    func stop() {
        stops += 1
        handler = nil
    }

    func send(at seconds: TimeInterval, yaw: Double = 0) {
        handler?(MotionSample(
            roll: 0.1, pitch: 0.2, yaw: yaw, rotationRate: [0, 0, 1], gravity: [0, -1, 0],
            userAcceleration: [0.01, 0, 0], timestamp: Date(timeIntervalSince1970: seconds)))
    }
}

/// The ledger's prompt, with the answer the test sets.
@MainActor
private final class Answering: LedgerPrompter {
    var answer: LedgerAnswer? = .always
    var asked = 0
    func askPermission(_ capability: String, notebook: String, id: Int, answer: @escaping @MainActor (LedgerAnswer?) -> Void) {
        asked += 1
        answer(self.answer)
    }

    func dismissPermission(_ id: Int) {}
}

@MainActor
final class MotionTests: XCTestCase {
    private lazy var prompter = Answering()
    private var nextID = 0

    private func bridge(_ motion: FakeMotion) -> DeviceBridge {
        let bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.ledgerPrompter = prompter
        bridge.setNotebook("a.ipynb", for: 1)
        bridge.addMotion(motion)
        return bridge
    }

    private func call(_ bridge: DeviceBridge, _ method: String, _ params: [String: Any] = [:], id: Int? = nil) -> [String: Any]? {
        nextID += 1
        var answer: [String: Any]?
        bridge.respond(to: ["id": id ?? nextID, "owner": 1, "method": method, "params": params]) { answer = $0 }
        return answer
    }

    private func errorCode(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["code"] as? String
    }

    private func values(_ reply: [String: Any]?) -> [[String: Any]] {
        (reply?["result"] as? [String: Any])?["values"] as? [[String: Any]] ?? []
    }

    func testHelloListsMotionOnlyWithSensors() {
        XCTAssertTrue(bridge(FakeMotion()).capabilities.contains("motion.latest"))
        let none = FakeMotion()
        none.isAvailable = false
        XCTAssertFalse(bridge(none).capabilities.contains { $0.hasPrefix("motion.") })
        #if os(macOS)
        let mac = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        mac.addMotion()
        XCTAssertFalse(mac.capabilities.contains { $0.hasPrefix("motion.") }, "a Mac has no motion sensors")
        #endif
    }

    func testTheLedgerAsksAndADenyRejects() {
        prompter.answer = .deny
        let motion = FakeMotion()
        let bridge = bridge(motion)
        XCTAssertEqual(errorCode(call(bridge, "motion.latest")), "denied")
        XCTAssertEqual(errorCode(call(bridge, "motion.watch")), "denied")
        XCTAssertEqual(prompter.asked, 1, "the deny is kept")
        XCTAssertFalse(motion.running)
        XCTAssertEqual(call(bridge, "motion.authorizationStatus")?["result"] as? String, "denied")
    }

    func testLatestStartsTheSensorsAndAnswersTheFirstSample() throws {
        let motion = FakeMotion()
        let bridge = bridge(motion)
        var answer: [String: Any]?
        bridge.respond(to: ["id": 1, "owner": 1, "method": "motion.latest", "params": [:]]) { answer = $0 }
        XCTAssertNil(answer)
        XCTAssertEqual(motion.intervals, [0.1])
        motion.send(at: 1_700_000_000, yaw: 0.3)
        let sample = try XCTUnwrap(answer?["result"] as? [String: Any])
        XCTAssertEqual((sample["attitude"] as? [String: Any])?["yaw"] as? Double, 0.3)
        XCTAssertEqual((sample["gravity"] as? [String: Any])?["y"] as? Double, -1)
        XCTAssertEqual(sample["timestamp"] as? Double, 1_700_000_000_000)

        // Warm: the next call answers with the newest at once.
        motion.send(at: 1_700_000_000.1, yaw: 0.4)
        let again = call(bridge, "motion.latest")?["result"] as? [String: Any]
        XCTAssertEqual((again?["attitude"] as? [String: Any])?["yaw"] as? Double, 0.4)
        XCTAssertEqual(motion.intervals, [0.1], "no restart")
    }

    func testLatestGoesColdAfterItsLastCall() {
        var clock = Date(timeIntervalSince1970: 0)
        let motion = FakeMotion()
        let hub = MotionHub(provider: motion, now: { clock })
        _ = hub.latest { _ in }
        motion.send(at: 0)
        clock = clock.addingTimeInterval(MotionHub.keepWarm - 1)
        motion.send(at: 9)
        XCTAssertTrue(motion.running)
        clock = clock.addingTimeInterval(2)
        motion.send(at: 11)
        XCTAssertFalse(motion.running, "stopped about 10 s after the last call")
        XCTAssertNil(hub.newest)
    }

    func testCancellingAWaitingLatestStopsTheSensors() {
        let motion = FakeMotion()
        let bridge = bridge(motion)
        var answer: [String: Any]?
        bridge.respond(to: ["id": 5, "owner": 1, "method": "motion.latest", "params": [:]]) { answer = $0 }
        XCTAssertTrue(motion.running)
        _ = bridge.handle(["id": 5, "cancel": true])
        XCTAssertEqual(errorCode(answer), "cancelled")
        // Still warm for a while: the next call would want it soon.
        XCTAssertTrue(motion.running)
    }

    func testWatchStreamsAtItsIntervalAndStopsOnClose() throws {
        let motion = FakeMotion()
        let bridge = bridge(motion)
        let opened = call(bridge, "motion.watch", ["interval": 0.5], id: 1)
        let stream = try XCTUnwrap((opened?["result"] as? [String: Any])?["stream"] as? Int)
        XCTAssertEqual(motion.intervals, [0.5])
        motion.send(at: 0)
        motion.send(at: 0.1)
        motion.send(at: 0.5)
        XCTAssertEqual(values(call(bridge, "stream.next", ["stream": stream])).count, 2, "the 0.1 s sample is skipped")
        _ = call(bridge, "stream.close", ["stream": stream])
        XCTAssertFalse(motion.running)
    }

    func testTheFastestWatchSetsTheRateAndEachKeepsItsOwn() throws {
        let motion = FakeMotion()
        let bridge = bridge(motion)
        let slow = try XCTUnwrap(((call(bridge, "motion.watch", ["interval": 1], id: 1))?["result"] as? [String: Any])?["stream"] as? Int)
        let fast = try XCTUnwrap(((call(bridge, "motion.watch", ["interval": 0.25], id: 2))?["result"] as? [String: Any])?["stream"] as? Int)
        XCTAssertEqual(motion.intervals, [1, 0.25])
        for t in stride(from: 0.0, through: 1.0, by: 0.25) { motion.send(at: t) }
        XCTAssertEqual(values(call(bridge, "stream.next", ["stream": fast])).count, 5)
        XCTAssertEqual(values(call(bridge, "stream.next", ["stream": slow])).count, 2)
        _ = call(bridge, "stream.close", ["stream": fast])
        XCTAssertEqual(motion.intervals.last, 1, "back to the slower rate")
    }

    func testAReleaseStopsTheSensors() throws {
        let motion = FakeMotion()
        let bridge = bridge(motion)
        _ = call(bridge, "motion.watch", id: 1)
        XCTAssertEqual(motion.intervals, [0.1], "0.1 s by default")
        bridge.dropPage()
        XCTAssertFalse(motion.running)
    }

    func testWatchChecksTheInterval() {
        let motion = FakeMotion()
        let bridge = bridge(motion)
        XCTAssertEqual(errorCode(call(bridge, "motion.watch", ["interval": 0.001])), "failed")
        XCTAssertEqual(errorCode(call(bridge, "motion.watch", ["interval": "fast"])), "failed")
        XCTAssertFalse(motion.running)
        XCTAssertEqual(prompter.asked, 0, "a bad interval fails before the ledger asks")
    }
}
