@testable import DeviceBridge
import XCTest

/// A test-only source: the test sends values through its sink.
@MainActor
private final class TickSource: StreamSource {
    let sink: StreamSink
    var stops = 0

    init(sink: StreamSink) {
        self.sink = sink
    }

    func stop() { stops += 1 }
}

@MainActor
private final class Collected {
    var all: [[String: Any]] = []
    var last: [String: Any]? { all.last }
    lazy var reply: ([String: Any]) -> Void = { [unowned self] in self.all.append($0) }
}

@MainActor
final class StreamsTests: XCTestCase {
    private var sources: [TickSource] = []

    /// A bridge with `test.ticks`, whose sources land in `sources`.
    private func bridge(capacity: Int = 4, refuse: DeviceCallError? = nil) -> DeviceBridge {
        let bridge = DeviceBridge(clipboard: nil, appVersion: "")
        bridge.addStream("test.ticks", capacity: capacity) { [unowned self] _, sink in
            if let refuse { throw refuse }
            let source = TickSource(sink: sink)
            self.sources.append(source)
            return source
        }
        return bridge
    }

    private func open(_ bridge: DeviceBridge, id: Int = 1, owner: Int = 1) -> Int? {
        let reply = bridge.handle(["id": id, "owner": owner, "method": "test.ticks", "params": [:]])
        return (reply["result"] as? [String: Any])?["stream"] as? Int
    }

    private func next(_ bridge: DeviceBridge, stream: Int, id: Int, into replies: Collected) {
        bridge.respond(to: ["id": id, "owner": 1, "method": "stream.next", "params": ["stream": stream]], reply: replies.reply)
    }

    private func values(_ reply: [String: Any]?) -> [Int] {
        ((reply?["result"] as? [String: Any])?["values"] as? [Any])?.compactMap { $0 as? Int } ?? []
    }

    private func field(_ reply: [String: Any]?, _ key: String) -> Any? {
        (reply?["result"] as? [String: Any])?[key]
    }

    private func errorCode(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["code"] as? String
    }

    func testHelloListsAStreamingMethod() {
        let bridge = bridge()
        let hello = bridge.handle(["id": 1, "method": "hello", "params": [:]])["result"] as? [String: Any]
        XCTAssertTrue((hello?["capabilities"] as? [String])?.contains("test.ticks") ?? false)
        XCTAssertFalse(DeviceBridge.remoteMethods.contains("test.ticks"))
    }

    func testValuesArriveInOrderAndAWaitingReadIsAnswered() throws {
        let bridge = bridge()
        let stream = try XCTUnwrap(open(bridge))
        XCTAssertEqual(stream, 1, "a stream's id is its opening call's")
        sources[0].sink.send(1)
        sources[0].sink.send(2)
        let replies = Collected()
        next(bridge, stream: stream, id: 2, into: replies)
        XCTAssertEqual(values(replies.last), [1, 2])
        next(bridge, stream: stream, id: 3, into: replies)
        XCTAssertEqual(replies.all.count, 1, "waits for a value")
        sources[0].sink.send(3)
        XCTAssertEqual(values(replies.last), [3])
    }

    func testAFullQueueDropsTheOldest() throws {
        let bridge = bridge(capacity: 3)
        let stream = try XCTUnwrap(open(bridge))
        for n in 1 ... 7 { sources[0].sink.send(n) }
        let replies = Collected()
        next(bridge, stream: stream, id: 2, into: replies)
        XCTAssertEqual(values(replies.last), [5, 6, 7])
        XCTAssertEqual(field(replies.last, "dropped") as? Int, 4)
    }

    func testFinishEndsAfterTheQueuedValues() throws {
        let bridge = bridge()
        let stream = try XCTUnwrap(open(bridge))
        sources[0].sink.send(1)
        sources[0].sink.finish()
        let replies = Collected()
        next(bridge, stream: stream, id: 2, into: replies)
        XCTAssertEqual(values(replies.last), [1])
        XCTAssertEqual(field(replies.last, "end") as? Bool, true)
        XCTAssertEqual(sources[0].stops, 0, "a source that ended itself isn't stopped")
        next(bridge, stream: stream, id: 3, into: replies)
        XCTAssertEqual(errorCode(replies.last), "failed", "the stream is gone")
    }

    func testAnErrorComesAfterTheQueuedValues() throws {
        let bridge = bridge()
        let stream = try XCTUnwrap(open(bridge))
        sources[0].sink.send(1)
        sources[0].sink.finish(DeviceCallError("denied", "no"))
        let replies = Collected()
        next(bridge, stream: stream, id: 2, into: replies)
        XCTAssertEqual(values(replies.last), [1])
        next(bridge, stream: stream, id: 3, into: replies)
        XCTAssertEqual(errorCode(replies.last), "denied")
    }

    func testCloseStopsTheSourceAndEndsAWaitingRead() throws {
        let bridge = bridge()
        let stream = try XCTUnwrap(open(bridge))
        let replies = Collected()
        next(bridge, stream: stream, id: 2, into: replies)
        XCTAssertNotNil(bridge.handle(["id": 3, "owner": 1, "method": "stream.close", "params": ["stream": stream]])["result"])
        XCTAssertEqual(sources[0].stops, 1)
        XCTAssertEqual(field(replies.last, "end") as? Bool, true)
        sources[0].sink.send(9)
        XCTAssertEqual(replies.all.count, 1, "a stopped stream sends nothing more")
    }

    func testCancellingAWaitingReadStopsTheSource() throws {
        let bridge = bridge()
        let stream = try XCTUnwrap(open(bridge))
        let replies = Collected()
        next(bridge, stream: stream, id: 2, into: replies)
        _ = bridge.handle(["id": 2, "cancel": true])
        XCTAssertEqual(errorCode(replies.last), "cancelled")
        XCTAssertEqual(sources[0].stops, 1)
    }

    func testCancellingTheOpeningCallStopsTheSource() throws {
        let bridge = bridge()
        let stream = try XCTUnwrap(open(bridge, id: 5))
        _ = bridge.handle(["id": stream, "cancel": true])
        XCTAssertEqual(sources[0].stops, 1)
    }

    func testAReleaseOrANewHelloStopsThatOwnersStreams() throws {
        let bridge = bridge()
        _ = try XCTUnwrap(open(bridge, id: 1, owner: 1))
        _ = try XCTUnwrap(open(bridge, id: 2, owner: 2))
        _ = bridge.handle(["owner": 1, "release": true])
        XCTAssertEqual(sources.map(\.stops), [1, 0])
        _ = bridge.handle(["id": 3, "owner": 2, "method": "hello", "params": [:]])
        XCTAssertEqual(sources.map(\.stops), [1, 1])
    }

    func testDropPageStopsOnlyTheKernelPagesStreams() throws {
        let bridge = bridge()
        _ = try XCTUnwrap(open(bridge, id: 1, owner: 1))
        // What respondRemote makes of a remote owner; remote kernels can't
        // open streams, but a stream under a negative owner is the remote page's.
        _ = try XCTUnwrap(open(bridge, id: -1, owner: -1))
        bridge.dropPage()
        XCTAssertEqual(sources.map(\.stops), [1, 0])
        bridge.dropRemote()
        XCTAssertEqual(sources.map(\.stops), [1, 1])
    }

    func testARemoteKernelCantStream() {
        let bridge = bridge()
        let replies = Collected()
        bridge.respondRemote(to: ["id": 1, "owner": 1, "method": "test.ticks", "params": [:]], reply: replies.reply)
        XCTAssertEqual(errorCode(replies.last), "unavailable")
        bridge.respondRemote(to: ["id": 2, "owner": 1, "method": "stream.next", "params": ["stream": 1]], reply: replies.reply)
        XCTAssertEqual(errorCode(replies.last), "unavailable")
        XCTAssertTrue(sources.isEmpty)
    }

    func testARefusedStartAnswersItsCode() {
        let bridge = bridge(refuse: DeviceCallError("denied", "not allowed"))
        let reply = bridge.handle(["id": 1, "owner": 1, "method": "test.ticks", "params": [:]])
        XCTAssertEqual(errorCode(reply), "denied")
    }

    func testOneKernelHasALimitedNumberOpen() {
        let bridge = bridge()
        for id in 1 ... Streams.maxOpen { XCTAssertNotNil(open(bridge, id: id)) }
        let reply = bridge.handle(["id": 100, "owner": 1, "method": "test.ticks", "params": [:]])
        XCTAssertEqual(errorCode(reply), "failed")
        XCTAssertNotNil(open(bridge, id: 101, owner: 2), "another kernel still can")
    }
}
