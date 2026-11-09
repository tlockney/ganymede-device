@testable import DeviceBridge
import XCTest

/// A device state the test changes.
@MainActor
private final class ChangingState: DeviceState {
    var darkMode = false
    var battery: [String: Any]? = ["level": 0.5, "charging": false]
    var locale = "en-US"

    func current() -> [String: Any] {
        var state: [String: Any] = ["darkMode": darkMode, "locale": locale]
        state["battery"] = battery
        return state
    }
}

/// A source the test drives: `check()` and `lifecycle` run when it says.
@MainActor
private final class ManualSource: HostEventSource {
    var check: (() -> Void)?
    var lifecycle: ((String) -> Void)?
    var running = 0

    func start(check: @escaping @MainActor () -> Void, lifecycle: @escaping @MainActor (String) -> Void) -> () -> Void {
        self.check = check
        self.lifecycle = lifecycle
        running += 1
        return { [weak self] in self?.running -= 1 }
    }
}

@MainActor
private final class Collected {
    var all: [[String: Any]] = []
    lazy var reply: ([String: Any]) -> Void = { [unowned self] in self.all.append($0) }
}

@MainActor
final class HostEventsTests: XCTestCase {
    private let state = ChangingState()
    private let source = ManualSource()

    private func bridge() -> DeviceBridge {
        let bridge = DeviceBridge(clipboard: nil, state: state, appVersion: "")
        bridge.addHostEvents(source)
        return bridge
    }

    private func open(_ bridge: DeviceBridge, _ params: [String: Any] = [:], id: Int = 1) -> [String: Any] {
        bridge.handle(["id": id, "owner": 1, "method": "events.watch", "params": params])
    }

    /// The values queued so far, read with one `stream.next`.
    private func read(_ bridge: DeviceBridge, stream: Int, id: Int) -> [[String: Any]] {
        let replies = Collected()
        bridge.respond(to: ["id": id, "owner": 1, "method": "stream.next", "params": ["stream": stream]], reply: replies.reply)
        return ((replies.all.last?["result"] as? [String: Any])?["values"] as? [[String: Any]]) ?? []
    }

    private func events(_ values: [[String: Any]]) -> [String] {
        values.compactMap { $0["event"] as? String }
    }

    func testHelloListsIt() {
        XCTAssertTrue(bridge().capabilities.contains("events.watch"))
        XCTAssertFalse(DeviceBridge(clipboard: nil, appVersion: "").capabilities.contains("events.watch"))
    }

    func testSendsChangesOnly() throws {
        let bridge = bridge()
        let stream = try XCTUnwrap((open(bridge)["result"] as? [String: Any])?["stream"] as? Int)
        XCTAssertEqual(source.running, 1)
        // Nothing changed: nothing sent, not even the starting state.
        source.check?()
        state.darkMode = true
        source.check?()
        source.check?()
        state.locale = "fr-FR"
        state.battery = ["level": 0.4, "charging": true]
        source.check?()
        source.lifecycle?("background")
        source.lifecycle?("foreground")
        let values = read(bridge, stream: stream, id: 2)
        XCTAssertEqual(events(values), ["appearance", "battery", "locale", "background", "foreground"])
        XCTAssertEqual(values[0]["value"] as? String, "dark")
        XCTAssertEqual((values[1]["value"] as? [String: Any])?["charging"] as? Bool, true)
        XCTAssertEqual(values[2]["value"] as? String, "fr-FR")
        XCTAssertTrue(values[3]["value"] is NSNull)
    }

    func testOnlyTheEventsAskedFor() throws {
        let bridge = bridge()
        let stream = try XCTUnwrap((open(bridge, ["events": ["locale", "foreground"]])["result"] as? [String: Any])?["stream"] as? Int)
        state.darkMode = true
        state.locale = "de-DE"
        source.check?()
        source.lifecycle?("background")
        source.lifecycle?("foreground")
        XCTAssertEqual(events(read(bridge, stream: stream, id: 2)), ["locale", "foreground"])
    }

    func testNoBatteryNeverSendsBattery() throws {
        state.battery = nil
        let bridge = bridge()
        let stream = try XCTUnwrap((open(bridge)["result"] as? [String: Any])?["stream"] as? Int)
        source.check?()
        state.darkMode = true
        source.check?()
        XCTAssertEqual(events(read(bridge, stream: stream, id: 2)), ["appearance"])
    }

    func testClosingAndReleasingStopTheSource() throws {
        let bridge = bridge()
        let stream = try XCTUnwrap((open(bridge)["result"] as? [String: Any])?["stream"] as? Int)
        _ = bridge.handle(["owner": 1, "method": "stream.close", "params": ["stream": stream]])
        XCTAssertEqual(source.running, 0)
        _ = open(bridge, id: 3)
        XCTAssertEqual(source.running, 1)
        // A kernel restart says hello again.
        _ = bridge.handle(["owner": 1, "method": "hello", "params": [:]])
        XCTAssertEqual(source.running, 0)
    }

    func testBadEventsFail() {
        let bridge = bridge()
        for events in [["weather"], [], "locale"] as [Any] {
            let error = open(bridge, ["events": events])["error"] as? [String: Any]
            XCTAssertEqual(error?["code"] as? String, "failed", "\(events)")
        }
        XCTAssertEqual(source.running, 0)
    }
}
