import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Host events (docs/protocol.md, "Host events"): `events.watch` is a
// stream of `{ event, value }` as the device changes, which the cell's
// `device.on(event, handler)` reads. Events: `appearance` ("light" or
// "dark"), `foreground` and `background` (null), `battery` ({ level,
// charging }) and `locale` (a BCP 47 tag). Each is sent only when it
// changes, never its starting state. No permission. The app turns it on
// with `DeviceBridge.addHostEvents()`.

/// When to look for changes. The system's runs `check` on a timer and on
/// the notifications that announce a change, and `lifecycle` as the app
/// comes to the front or leaves it.
@MainActor
public protocol HostEventSource {
    /// Starts watching; the answer stops it.
    func start(check: @escaping @MainActor () -> Void, lifecycle: @escaping @MainActor (_ event: String) -> Void) -> () -> Void
}

/// The system's: locale and battery notifications, the app's activation,
/// and a check each second for what has no notification of its own (the
/// appearance, and a Mac's battery).
@MainActor
public struct SystemHostEventSource: HostEventSource {
    public init() {}

    public func start(check: @escaping @MainActor () -> Void, lifecycle: @escaping @MainActor (String) -> Void) -> () -> Void {
        let center = NotificationCenter.default
        var observers: [NSObjectProtocol] = []
        func observe(_ name: Notification.Name, _ run: @escaping @MainActor () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { run() }
            })
        }
        observe(NSLocale.currentLocaleDidChangeNotification, check)
        #if os(macOS)
        observe(NSApplication.didBecomeActiveNotification) { lifecycle("foreground") }
        observe(NSApplication.didResignActiveNotification) { lifecycle("background") }
        #else
        observe(UIApplication.willEnterForegroundNotification) { lifecycle("foreground") }
        observe(UIApplication.didEnterBackgroundNotification) { lifecycle("background") }
        observe(UIDevice.batteryStateDidChangeNotification, check)
        observe(UIDevice.batteryLevelDidChangeNotification, check)
        #endif
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { check() }
        }
        return {
            timer.invalidate()
            observers.forEach(center.removeObserver)
        }
    }
}

/// One `events.watch` stream: what it last sent, so it sends changes only.
@MainActor
private final class HostEventWatch: StreamSource {
    private let sink: StreamSink
    private let events: Set<String>
    private let state: DeviceState
    private var last: [String: NSObject] = [:]
    private var stopSource: (() -> Void)?

    init(sink: StreamSink, events: Set<String>, state: DeviceState, source: HostEventSource) {
        self.sink = sink
        self.events = events
        self.state = state
        last = values()
        stopSource = source.start(
            check: { [weak self] in self?.check() },
            lifecycle: { [weak self] event in self?.lifecycle(event) }
        )
    }

    func stop() {
        stopSource?()
        stopSource = nil
    }

    private func check() {
        let now = values()
        for event in ["appearance", "battery", "locale"] where events.contains(event) {
            guard let value = now[event], value != last[event] else { continue }
            sink.send(["event": event, "value": value])
        }
        last = now
    }

    private func lifecycle(_ event: String) {
        guard events.contains(event) else { return }
        sink.send(["event": event, "value": NSNull()])
        // Coming back may follow changes made while away.
        check()
    }

    /// The watched values now, as replies carry them. A Mac without a
    /// battery has none, so never sends `battery`.
    private func values() -> [String: NSObject] {
        let current = state.current()
        var values: [String: NSObject] = [:]
        if let dark = current["darkMode"] as? Bool { values["appearance"] = (dark ? "dark" : "light") as NSString }
        if let battery = current["battery"] as? [String: Any] { values["battery"] = battery as NSDictionary }
        if let locale = current["locale"] as? String { values["locale"] = locale as NSString }
        return values
    }
}

extension DeviceBridge {
    /// Every event `events.watch` sends.
    public static let hostEvents: Set<String> = ["appearance", "foreground", "background", "battery", "locale"]

    /// Turns on `events.watch`, the stream behind the cell's `device.on`:
    /// `hello` lists it. `source` is the system's by default.
    public func addHostEvents(_ source: HostEventSource? = nil) {
        // Made here, not as the default argument: defaults are evaluated
        // outside the main actor.
        let source = source ?? SystemHostEventSource()
        let state = self.state
        addStream("events.watch", capacity: 64, check: { _ = try Self.watchedEvents($0) }) { params, sink in
            HostEventWatch(sink: sink, events: try Self.watchedEvents(params), state: state, source: source)
        }
    }

    /// `events`, a list of event names; every event when left out.
    static func watchedEvents(_ params: [String: Any]) throws -> Set<String> {
        guard let value = params["events"], !(value is NSNull) else { return hostEvents }
        guard let names = value as? [String], !names.isEmpty, Set(names).isSubset(of: hostEvents) else {
            throw DeviceCallError(
                "failed", "events.watch: events must be a list of \(hostEvents.sorted().joined(separator: ", "))"
            )
        }
        return Set(names)
    }
}
