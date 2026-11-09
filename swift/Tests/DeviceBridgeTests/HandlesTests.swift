@testable import DeviceBridge
import XCTest

/// Handles' lifetimes (docs/protocol.md, "Handles"), through a test-only
/// kind the test opens on the bridge's registry directly.
@MainActor
final class HandlesTests: XCTestCase {
    private var closed: [Int] = []

    private func bridge() -> DeviceBridge {
        DeviceBridge(clipboard: nil, appVersion: "")
    }

    private func open(_ bridge: DeviceBridge, owner: Int = 1, call: Int? = nil, limit: Int = 4) -> Int? {
        bridge.handles.open(owner: owner, kind: "test.thing", limit: limit, call: call) { [unowned self] id in
            self.closed.append(id)
        }
    }

    func testHandleCloseClosesOnceAndOnlyTheOwners() throws {
        let bridge = bridge()
        let id = try XCTUnwrap(open(bridge))
        XCTAssertTrue(bridge.handles.isOpen(id, owner: 1, kind: "test.thing"))
        // Another kernel's handle is no handle at all to this one.
        XCTAssertFalse(bridge.handles.isOpen(id, owner: 2, kind: "test.thing"))
        XCTAssertFalse(bridge.handles.isOpen(id, owner: 1, kind: "sound.player"))
        XCTAssertTrue(bridge.handle(["owner": 2, "method": "handle.close", "params": ["handle": id]])["result"] is NSNull)
        XCTAssertEqual(closed, [])
        XCTAssertTrue(bridge.handle(["owner": 1, "method": "handle.close", "params": ["handle": id]])["result"] is NSNull)
        XCTAssertEqual(closed, [id])
        // A second close is fine and closes nothing.
        XCTAssertTrue(bridge.handle(["owner": 1, "method": "handle.close", "params": ["handle": id]])["result"] is NSNull)
        XCTAssertEqual(closed, [id])
        XCTAssertFalse(bridge.handles.isOpen(id, owner: 1, kind: "test.thing"))
        let error = bridge.handle(["owner": 1, "method": "handle.close", "params": [:]])["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "failed")
    }

    func testReleaseAndHelloCloseTheOwnersHandles() throws {
        let bridge = bridge()
        let a = try XCTUnwrap(open(bridge, owner: 1))
        let b = try XCTUnwrap(open(bridge, owner: 2))
        _ = bridge.handle(["owner": 1, "release": true])
        XCTAssertEqual(closed, [a])
        _ = bridge.handle(["owner": 2, "method": "hello", "params": [:]])
        XCTAssertEqual(closed, [a, b])
    }

    func testDropsCloseTheirSide() throws {
        let bridge = bridge()
        let page = try XCTUnwrap(open(bridge, owner: 1))
        let remote = try XCTUnwrap(open(bridge, owner: -1))
        bridge.dropRemote()
        XCTAssertEqual(closed, [remote])
        bridge.dropPage()
        XCTAssertEqual(closed, [remote, page])
        let other = try XCTUnwrap(open(bridge, owner: 3))
        bridge.dropAll()
        XCTAssertEqual(closed, [remote, page, other])
    }

    func testCancelOfTheOpeningCallClosesIt() throws {
        let bridge = bridge()
        let id = try XCTUnwrap(open(bridge, call: 7))
        _ = bridge.handle(["id": 8, "owner": 1, "cancel": true])
        XCTAssertEqual(closed, [])
        _ = bridge.handle(["id": 7, "owner": 1, "cancel": true])
        XCTAssertEqual(closed, [id])
    }

    func testTheLimitIsPerKernelAndKind() throws {
        let bridge = bridge()
        for _ in 0..<2 { XCTAssertNotNil(open(bridge, limit: 2)) }
        XCTAssertNil(open(bridge, limit: 2))
        XCTAssertNotNil(open(bridge, owner: 2, limit: 2))
        let other = bridge.handles.open(owner: 1, kind: "test.other", limit: 2, call: nil) { _ in }
        XCTAssertNotNil(other)
        XCTAssertEqual(bridge.handles.count(owner: 1, kind: "test.thing"), 2)
    }

    func testAPlayerIsAHandle() throws {
        // `handle.close` closes a sound player as `sound.close` does.
        let bridge = DeviceBridge(clipboard: nil, sounds: SilentLoader(), appVersion: "")
        let opened = bridge.handle(["id": 1, "owner": 1, "method": "sound.player", "params": ["data": ["base64": "AQI="]]])
        let id = try XCTUnwrap((opened["result"] as? [String: Any])?["player"] as? Int)
        XCTAssertTrue(bridge.handles.isOpen(id, owner: 1, kind: "sound.player"))
        _ = bridge.handle(["owner": 1, "method": "handle.close", "params": ["handle": id]])
        let control = bridge.handle(["owner": 1, "method": "sound.control", "params": ["player": id]])
        XCTAssertEqual((control["error"] as? [String: Any])?["code"] as? String, "failed")
    }
}

/// Sounds that never play.
@MainActor
private final class SilentLoader: SoundLoader {
    func load(_ data: Data) throws -> SoundPlayback { Silent() }
}

@MainActor
private final class Silent: SoundPlayback {
    var duration: TimeInterval = 1
    var currentTime: TimeInterval = 0
    var isPlaying = false
    var volume: Float = 1
    var onFinish: (() -> Void)?
    func play() -> Bool { true }
    func pause() {}
}
