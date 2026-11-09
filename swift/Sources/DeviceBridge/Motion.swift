import Foundation
#if os(iOS)
import CoreMotion
#endif

// `device.motion` (docs/protocol.md, "Motion"): Core Motion's device
// motion, as a stream (`motion.watch`) and a snapshot (`motion.latest`)
// sharing one source, which runs at the fastest interval anyone asked for
// and stops when no one needs it. iPad and iPhone only. The system has no
// prompt for these sensors, so the permission is the ledger's alone.
// The app turns the namespace on with `DeviceBridge.addMotion()`.

/// One device motion reading.
public struct MotionSample: Sendable, Equatable {
    /// Radians.
    public var roll, pitch, yaw: Double
    /// Radians per second around x, y and z.
    public var rotationRate: SIMD3<Double>
    /// In g, along x, y and z.
    public var gravity: SIMD3<Double>
    public var userAcceleration: SIMD3<Double>
    public var timestamp: Date

    public init(
        roll: Double, pitch: Double, yaw: Double, rotationRate: SIMD3<Double>, gravity: SIMD3<Double>,
        userAcceleration: SIMD3<Double>, timestamp: Date
    ) {
        self.roll = roll
        self.pitch = pitch
        self.yaw = yaw
        self.rotationRate = rotationRate
        self.gravity = gravity
        self.userAcceleration = userAcceleration
        self.timestamp = timestamp
    }
}

/// Where samples come from, behind a protocol so tests needn't use Core Motion.
@MainActor
public protocol MotionProvider: AnyObject {
    /// Whether the device has the sensors.
    var isAvailable: Bool { get }
    /// Delivers samples about every `interval` seconds, replacing any
    /// earlier start's interval and handlers. `failed` means updates have
    /// stopped: the hub ends every call waiting on them.
    func start(
        interval: TimeInterval, handler: @escaping @MainActor (MotionSample) -> Void,
        failed: @escaping @MainActor (DeviceCallError) -> Void
    )
    func stop()
}

/// The motion "permission": the system has none for device motion, so it
/// is always granted and only the ledger asks.
@MainActor
final class LedgerOnlyPermission: Permission {
    var status: PermissionStatus { .authorized }
    func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) { done(.authorized) }
}

#if os(iOS)
/// CMMotionManager's device motion, on the main queue.
@MainActor
public final class SystemMotionProvider: MotionProvider {
    private let manager = CMMotionManager()

    public init() {}

    public var isAvailable: Bool { manager.isDeviceMotionAvailable }

    public func start(
        interval: TimeInterval, handler: @escaping @MainActor (MotionSample) -> Void,
        failed: @escaping @MainActor (DeviceCallError) -> Void
    ) {
        manager.deviceMotionUpdateInterval = interval
        // Uptime to wall clock: Core Motion stamps samples since boot.
        let offset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        manager.startDeviceMotionUpdates(to: .main) { [manager] motion, error in
            MainActor.assumeIsolated {
                if let error {
                    manager.stopDeviceMotionUpdates()
                    failed(DeviceCallError("failed", "motion: \(error.localizedDescription)"))
                    return
                }
                guard let motion else { return }
                handler(MotionSample(
                    roll: motion.attitude.roll, pitch: motion.attitude.pitch, yaw: motion.attitude.yaw,
                    rotationRate: [motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z],
                    gravity: [motion.gravity.x, motion.gravity.y, motion.gravity.z],
                    userAcceleration: [motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z],
                    timestamp: Date(timeIntervalSince1970: offset + motion.timestamp)))
            }
        }
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
#endif

/// The one source both forms share: watches, each with its interval, and
/// `latest`'s cache, kept warm while calls keep coming.
@MainActor
final class MotionHub {
    static let latestInterval: TimeInterval = 0.1
    /// How long `latest` keeps the sensors running after its last call.
    static let keepWarm: TimeInterval = 10

    let provider: MotionProvider
    private let now: () -> Date

    #if os(iOS)
    /// Core Motion's hub, shared by every window's bridge: Apple asks for
    /// one CMMotionManager per app, and one source serves every caller.
    static let system = MotionHub(provider: SystemMotionProvider())
    #endif

    final class Watch: StreamSource {
        let interval: TimeInterval
        let sink: StreamSink
        weak var hub: MotionHub?
        /// When the next sample is due; nil before the first.
        var due: Date?

        init(interval: TimeInterval, sink: StreamSink, hub: MotionHub) {
            self.interval = interval
            self.sink = sink
            self.hub = hub
        }

        func stop() { hub?.remove(self) }
    }

    private var watches: [Watch] = []
    private(set) var newest: MotionSample?
    private var warmUntil: Date?
    private var waiting: [Int: (Result<MotionSample, DeviceCallError>) -> Void] = [:]
    private var nextWaiter = 0
    /// The interval the provider runs at, nil while stopped.
    private(set) var running: TimeInterval?

    init(provider: MotionProvider, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    func watch(interval: TimeInterval, sink: StreamSink) -> StreamSource {
        let watch = Watch(interval: interval, sink: sink, hub: self)
        watches.append(watch)
        update()
        return watch
    }

    fileprivate func remove(_ watch: Watch) {
        watches.removeAll { $0 === watch }
        update()
    }

    /// The newest sample, now while `latest` is warm, or once the next one
    /// comes. Returns a cancel.
    func latest(_ done: @escaping (Result<MotionSample, DeviceCallError>) -> Void) -> () -> Void {
        // Only `latest`'s own rate keeps `newest` fresh: a slow watch's
        // last sample may be a second old.
        let warm = latestWanted
        warmUntil = now().addingTimeInterval(Self.keepWarm)
        if warm, running != nil, let newest {
            done(.success(newest))
            // A slower watch's interval may be all that runs now.
            update()
            return {}
        }
        newest = nil
        nextWaiter += 1
        let key = nextWaiter
        waiting[key] = done
        update()
        return { [weak self] in
            self?.waiting[key] = nil
            self?.update()
        }
    }

    private var latestWanted: Bool {
        !waiting.isEmpty || (warmUntil.map { now() < $0 } ?? false)
    }

    /// Runs the provider at the fastest interval wanted, or stops it.
    private func update() {
        var intervals = watches.map(\.interval)
        if latestWanted { intervals.append(Self.latestInterval) }
        guard let interval = intervals.min() else {
            if running != nil {
                provider.stop()
                running = nil
                newest = nil
            }
            return
        }
        guard interval != running else { return }
        running = interval
        provider.start(
            interval: interval, handler: { [weak self] sample in self?.received(sample) },
            failed: { [weak self] error in self?.failed(error) })
    }

    /// Updates stopped: every waiting call and watch ends with `error`.
    private func failed(_ error: DeviceCallError) {
        let answers = waiting.values
        let ended = watches
        waiting = [:]
        watches = []
        warmUntil = nil
        newest = nil
        running = nil
        provider.stop()
        for answer in answers { answer(.failure(error)) }
        for watch in ended { watch.sink.finish(error) }
    }

    private func received(_ sample: MotionSample) {
        newest = sample
        let answers = waiting.values
        waiting = [:]
        for answer in answers { answer(.success(sample)) }
        let step = running ?? 0
        for watch in watches {
            // A slower watch takes the sample nearest each due time, so
            // over time it gets one every `interval` even when that isn't
            // a multiple of the source's.
            if let due = watch.due {
                if sample.timestamp < due.addingTimeInterval(-step / 2 - 0.000_1) { continue }
                // Fell more than an interval behind (a gap in samples):
                // start again from this one.
                let next = due.addingTimeInterval(watch.interval)
                watch.due = next < sample.timestamp ? sample.timestamp.addingTimeInterval(watch.interval) : next
            } else {
                watch.due = sample.timestamp.addingTimeInterval(watch.interval)
            }
            watch.sink.send(DeviceBridge.motionReply(sample))
        }
        // `latest` went cold: run slower for the watches, or stop.
        if !latestWanted { update() }
    }
}

extension DeviceBridge {
    /// Turns on `device.motion` where the device has the sensors: `hello`
    /// lists the trio, `motion.watch` and `motion.latest`. `provider` is
    /// Core Motion by default, through one source every bridge in the app
    /// shares; a Mac has none, so this does nothing there.
    public func addMotion(_ provider: MotionProvider? = nil) {
        #if os(iOS)
        let hub = provider.map { MotionHub(provider: $0) } ?? MotionHub.system
        #else
        guard let provider else { return }
        let hub = MotionHub(provider: provider)
        #endif
        guard hub.provider.isAvailable else { return }
        addPermission("motion", LedgerOnlyPermission())
        // A bad interval fails before the permission prompt.
        addStream("motion.watch", permission: "motion", check: { _ = try Self.motionInterval($0) }) { params, sink in
            hub.watch(interval: try Self.motionInterval(params), sink: sink)
        }
        addMethod("motion.latest", permission: "motion") { _, reply in
            hub.latest { reply($0.map { Self.motionReply($0) as Any }) }
        }
    }

    /// `motion.watch`'s interval: 0.1 s unless the call gives 0.01 to 1.
    private static func motionInterval(_ params: [String: Any]) throws -> TimeInterval {
        guard let value = params["interval"] else { return 0.1 }
        guard let number = (value as? NSNumber)?.doubleValue, number >= 0.01, number <= 1 else {
            throw DeviceCallError("failed", "motion.watch: interval must be 0.01 to 1 seconds")
        }
        return number
    }

    /// A sample as the cell reads it (src/device.ts `MotionSample`).
    static func motionReply(_ sample: MotionSample) -> [String: Any] {
        func xyz(_ v: SIMD3<Double>) -> [String: Any] { ["x": v.x, "y": v.y, "z": v.z] }
        return [
            "attitude": ["roll": sample.roll, "pitch": sample.pitch, "yaw": sample.yaw],
            "rotationRate": xyz(sample.rotationRate),
            "gravity": xyz(sample.gravity),
            "userAcceleration": xyz(sample.userAcceleration),
            "timestamp": (sample.timestamp.timeIntervalSince1970 * 1000).rounded(),
        ]
    }
}
