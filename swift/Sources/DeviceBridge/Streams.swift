import Foundation

// Bounded streams (docs/protocol.md, "Streams"). A streaming method answers
// its call with `{ stream }`, its call's id; its source then sends values
// into a queue that keeps the newest `capacity` and counts the ones it
// drops. The page pulls them with `stream.next`, which answers at once when
// values wait, or when the next one comes. `stream.close`, a cancelled
// `stream.next`, a cancel of the opening call, and the owner's release
// (a new `hello`, `release`, `dropPage()`, `dropRemote()`, `dropAll()`)
// stop the source.

/// A running source of stream values: a location or motion subscription,
/// or a test's timer. `stop()` is called once, when the stream is closed,
/// cancelled or released; not after the source ends it with `finish`.
@MainActor
public protocol StreamSource: AnyObject {
    func stop()
}

/// Why a call failed, with a `DeviceErrorCode` (src/errors.ts) for the
/// cell. Handlers throw it; any other error reaches the cell as `failed`.
public struct DeviceCallError: Error, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
}

/// Where a source sends its stream's values. Values are what a reply
/// carries: JSON-like (`String`, `NSNumber`/`Double`/`Bool`, `[Any]`,
/// `[String: Any]`, `NSNull`), bytes as `DeviceBridge.binary(_:)`.
@MainActor
public final class StreamSink {
    private weak var streams: Streams?
    private let id: Int
    /// The stream this sink feeds. Ids start over when the page reloads,
    /// so the id alone could reach a newer stream; this can't.
    private weak var stream: Streams.Open?

    fileprivate init(streams: Streams, id: Int, stream: Streams.Open) {
        self.streams = streams
        self.id = id
        self.stream = stream
    }

    /// Whether the stream is still open and its bridge still alive. A
    /// source shared beyond one bridge checks this to let go of streams
    /// whose bridge went away without closing them.
    public var isOpen: Bool { stream != nil && streams != nil }

    /// Queues `value`, dropping the oldest when the queue is full.
    /// Ignored once the stream has ended.
    public func send(_ value: Any) {
        guard let stream else { return }
        streams?.send(value, to: id, stream)
    }

    /// Ends the stream: the cell reads what is queued, then the loop ends,
    /// or, with `error`, throws it. Ignored once the stream has ended.
    public func finish(_ error: DeviceCallError? = nil) {
        guard let stream else { return }
        streams?.finish(id, stream, error)
    }
}

/// Starts a streaming method's source for one call. Throw a
/// `DeviceCallError` to refuse it (`denied`, `unavailable`, `failed`).
public typealias StreamStarter = @MainActor (_ params: [String: Any], _ sink: StreamSink) throws -> StreamSource

/// The streams a bridge has open.
@MainActor
final class Streams {
    /// Streams one kernel may have open at once, so a loop that forgets to
    /// close them fails rather than running sources without end.
    static let maxOpen = 16

    struct Method {
        let capacity: Int
        let start: StreamStarter
    }

    fileprivate final class Open {
        let owner: Int
        let capacity: Int
        var source: StreamSource?
        var queue: [Any] = []
        var dropped = 0
        /// The last reply once the source ended: `end`, or an error.
        var ended: [String: Any]?
        /// The `stream.next` waiting for a value: its call id and reply.
        var waiting: (call: Int, reply: ([String: Any]) -> Void)?

        init(owner: Int, capacity: Int) {
            self.owner = owner
            self.capacity = capacity
        }
    }

    private(set) var methods: [String: Method] = [:]
    private var open: [Int: Open] = [:]

    func add(_ method: String, capacity: Int, start: @escaping StreamStarter) {
        methods[method] = Method(capacity: max(1, capacity), start: start)
    }

    /// Opens a stream for `method`. Its id is the call's.
    func start(_ method: String, _ params: [String: Any], call: Int?, owner: Int) -> [String: Any] {
        guard let starter = methods[method] else {
            return DeviceBridge.error("unavailable", "\(method) isn't available in this app")
        }
        guard let call else {
            return DeviceBridge.error("failed", "a stream needs a numeric call id, so it can be read and cancelled")
        }
        guard open[call] == nil else {
            return DeviceBridge.error("failed", "stream \(call) is already open")
        }
        guard open.values.filter({ $0.owner == owner }).count < Self.maxOpen else {
            return DeviceBridge.error("failed", "\(method): \(Self.maxOpen) streams are open; stop one first")
        }
        let stream = Open(owner: owner, capacity: starter.capacity)
        // In place before the source starts, so a value it sends at once is kept.
        open[call] = stream
        do {
            let source = try starter.start(params, StreamSink(streams: self, id: call, stream: stream))
            if stream.ended == nil, open[call] === stream {
                stream.source = source
            }
        } catch {
            open[call] = nil
            if let error = error as? DeviceCallError {
                return DeviceBridge.error(error.code, error.message)
            }
            return DeviceBridge.error("failed", "\(method): \(error)")
        }
        return ["result": ["stream": call]]
    }

    /// `stream.next`: replies with what is queued, or waits for a value.
    /// Only the kernel that opened the stream (`owner`) reaches it.
    func next(_ params: [String: Any], call: Int?, owner: Int, reply: @escaping ([String: Any]) -> Void) {
        guard let id = DeviceBridge.callID(params["stream"]), let stream = open[id], stream.owner == owner else {
            reply(DeviceBridge.error("failed", "stream.next: no such stream (it ended or was closed)"))
            return
        }
        guard let call else {
            reply(DeviceBridge.error("failed", "stream.next needs a numeric call id, so it can be cancelled"))
            return
        }
        guard stream.waiting == nil else {
            reply(DeviceBridge.error("failed", "stream.next: one read at a time"))
            return
        }
        if stream.queue.isEmpty, stream.ended == nil {
            stream.waiting = (call, reply)
        } else {
            reply(take(id, stream))
        }
    }

    /// `stream.close`: stops the source. A waiting `stream.next` gets the end.
    /// Another kernel's stream is left alone.
    func close(_ params: [String: Any], owner: Int) -> [String: Any] {
        if let id = DeviceBridge.callID(params["stream"]), open[id]?.owner == owner {
            end(id, reply: ["result": ["values": [Any](), "dropped": open[id]?.dropped ?? 0, "end": true]])
        }
        return ["result": NSNull()]
    }

    /// A cancel for call `call`: the opening call (the page dropped its
    /// answer, so nothing else would close it), or a waiting `stream.next`.
    func cancel(_ call: Int) {
        if open[call] != nil {
            end(call, reply: DeviceBridge.error("cancelled", "the stream was cancelled"))
        }
        for (id, stream) in open where stream.waiting?.call == call {
            end(id, reply: DeviceBridge.error("cancelled", "stream.next was cancelled"))
        }
    }

    /// Stops the streams of each owner that `matches`.
    func stop(_ matches: (Int) -> Bool) {
        for (id, stream) in open where matches(stream.owner) {
            end(id, reply: DeviceBridge.error("cancelled", "the kernel stopped"))
        }
    }

    fileprivate func send(_ value: Any, to id: Int, _ stream: Open) {
        guard open[id] === stream, stream.ended == nil else { return }
        if stream.queue.count >= stream.capacity {
            stream.queue.removeFirst()
            stream.dropped += 1
        }
        stream.queue.append(value)
        answerWaiting(id, stream)
    }

    fileprivate func finish(_ id: Int, _ stream: Open, _ error: DeviceCallError?) {
        guard open[id] === stream, stream.ended == nil else { return }
        stream.source = nil
        stream.ended = error.map { DeviceBridge.error($0.code, $0.message) } ?? ["result": ["end": true]]
        answerWaiting(id, stream)
    }

    private func answerWaiting(_ id: Int, _ stream: Open) {
        guard let waiting = stream.waiting else { return }
        stream.waiting = nil
        waiting.reply(take(id, stream))
    }

    /// The reply to a `stream.next` with something to say: the queued
    /// values, with `end` when the source ended; or, with none queued, the
    /// source's error. An ended stream is forgotten once it has said so.
    private func take(_ id: Int, _ stream: Open) -> [String: Any] {
        let values = stream.queue
        stream.queue = []
        if let ended = stream.ended {
            if ended["error"] != nil, !values.isEmpty {
                // Values first; the error answers the next read.
                return ["result": ["values": values, "dropped": stream.dropped]]
            }
            open[id] = nil
            if ended["error"] != nil { return ended }
            return ["result": ["values": values, "dropped": stream.dropped, "end": true]]
        }
        return ["result": ["values": values, "dropped": stream.dropped]]
    }

    /// Forgets stream `id`, stops its source, and gives a waiting read `reply`.
    private func end(_ id: Int, reply: [String: Any]) {
        guard let stream = open.removeValue(forKey: id) else { return }
        let source = stream.source
        stream.source = nil
        source?.stop()
        if let waiting = stream.waiting {
            stream.waiting = nil
            waiting.reply(reply)
        }
    }
}
