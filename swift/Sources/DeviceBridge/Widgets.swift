import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

// `device.widget` (docs/phase-4.md, part 5): a widget can't run a script
// itself, so a run publishes what it shows. `widget.update` keeps the
// content per notebook and kind in a `WidgetStore` (the App Group's
// UserDefaults suite, which the widget extension reads too) and asks
// WidgetKit to redraw. The app turns it on with `DeviceBridge.addWidgets()`.

/// A widget's content: what `device.widget.update` sent, checked.
public struct WidgetContent: Codable, Equatable, Sendable {
    /// One row: text, or a number with an optional label and unit.
    public struct Row: Codable, Equatable, Sendable {
        public let text: String?
        public let label: String?
        public let value: Double?
        public let unit: String?
    }

    public static let tints = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray"]

    public let title: String?
    public let rows: [Row]
    public let tint: String?
    public let sparkline: [Double]

    /// `widget.update`'s `content`, with the limits the cell checks too.
    init(_ value: Any?) throws {
        func bad(_ why: String) -> DeviceCallError { DeviceCallError("failed", "widget.update: \(why)") }
        guard let content = value as? [String: Any] else { throw bad("content must be an object") }
        func text(_ value: Any?, _ max: Int, _ what: String) throws -> String? {
            guard let value, !(value is NSNull) else { return nil }
            guard let text = value as? String, text.utf16.count <= max else { throw bad("\(what) must be text up to \(max) characters") }
            return text
        }
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        title = try text(content["title"], 64, "title")
        let rows = content["rows"] as? [Any] ?? []
        guard content["rows"] == nil || content["rows"] is [Any], rows.count <= 6 else { throw bad("rows must be a list of at most 6") }
        self.rows = try rows.map { item in
            guard let row = item as? [String: Any] else { throw bad("each row is { text } or { label, value, unit }") }
            if row["value"] == nil {
                guard let line = try text(row["text"], 128, "a row's text") else { throw bad("each row is { text } or { label, value, unit }") }
                return Row(text: line, label: nil, value: nil, unit: nil)
            }
            guard let value = number(row["value"]) else { throw bad("a row's value must be a finite number") }
            return Row(text: nil, label: try text(row["label"], 32, "a row's label"), value: value, unit: try text(row["unit"], 32, "a row's unit"))
        }
        tint = try text(content["tint"], 16, "tint")
        if let tint, !Self.tints.contains(tint) { throw bad("tint must be one of \(Self.tints.joined(separator: ", "))") }
        let line = content["sparkline"] as? [Any] ?? []
        guard content["sparkline"] == nil || content["sparkline"] is [Any], line.count <= 64 else { throw bad("sparkline must be at most 64 finite numbers") }
        sparkline = try line.map { guard let n = number($0) else { throw bad("sparkline must be at most 64 finite numbers") }; return n }
    }
}

/// One published widget.
public struct PublishedWidget: Codable, Equatable, Sendable {
    public let notebook: String
    public let kind: String
    public let content: WidgetContent
    public let updated: Date
}

/// Where published widgets live, behind a protocol so tests needn't touch
/// UserDefaults.
@MainActor
public protocol WidgetStore {
    func load() -> [PublishedWidget]
    func save(_ widgets: [PublishedWidget])
    /// Asks the system to redraw widgets that show these.
    func reload()
}

/// The App Group's UserDefaults suite, which the widget extension reads
/// with `UserDefaultsWidgetStore(defaults:)` on the same suite. `widgetKind`
/// is the extension's `Widget` kind to reload.
@MainActor
public struct UserDefaultsWidgetStore: WidgetStore {
    public let key: String
    public let defaults: UserDefaults
    public let widgetKind: String?

    public init(key: String = "ganymede.device.widgets", defaults: UserDefaults = .standard, widgetKind: String? = nil) {
        self.key = key
        self.defaults = defaults
        self.widgetKind = widgetKind
    }

    public func load() -> [PublishedWidget] {
        Self.read(defaults, key: key)
    }

    /// What the suite holds, from any thread: for a widget's timeline
    /// provider, which doesn't run on the main actor.
    public nonisolated static func read(_ defaults: UserDefaults, key: String = "ganymede.device.widgets") -> [PublishedWidget] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PublishedWidget].self, from: data)) ?? []
    }

    public func save(_ widgets: [PublishedWidget]) {
        defaults.set(try? JSONEncoder().encode(widgets), forKey: key)
    }

    public func reload() {
        #if canImport(WidgetKit)
        if let widgetKind {
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        } else {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }
}

/// What notebooks published. Instances on one store share it.
@MainActor
public final class PublishedWidgets {
    private let store: WidgetStore
    /// The most a notebook keeps; its oldest go first, so one notebook
    /// can't push out another's.
    static let limit = 16

    public init(store: WidgetStore? = nil) {
        self.store = store ?? UserDefaultsWidgetStore()
    }

    /// Everything published, newest first: for a widget's configuration.
    public var all: [PublishedWidget] { store.load().sorted { $0.updated > $1.updated } }

    public func content(notebook: String, kind: String) -> WidgetContent? {
        store.load().first { $0.notebook == notebook && $0.kind == kind }?.content
    }

    func publish(_ content: WidgetContent, notebook: String, kind: String, at date: Date = Date()) {
        let others = store.load().filter { $0.notebook != notebook }
        var own = store.load().filter { $0.notebook == notebook && $0.kind != kind }
        own.append(PublishedWidget(notebook: notebook, kind: kind, content: content, updated: date))
        own.sort { $0.updated > $1.updated }
        store.save((others + own.prefix(Self.limit)).sorted { $0.updated > $1.updated })
        store.reload()
    }

    /// A notebook was renamed or moved: its widgets follow.
    public func move(from old: String, to new: String) {
        guard old != new else { return }
        let widgets = store.load()
        guard widgets.contains(where: { $0.notebook == old }) else { return }
        store.save(widgets.map { $0.notebook == old ? PublishedWidget(notebook: new, kind: $0.kind, content: $0.content, updated: $0.updated) : $0 })
        store.reload()
    }

    /// Forgets what `notebook` published.
    public func remove(notebook: String) {
        store.save(store.load().filter { $0.notebook != notebook })
        store.reload()
    }
}

extension DeviceBridge {
    /// Turns on `device.widget.update`. No permission: a widget shows only
    /// what the person configured it to.
    public func addWidgets(_ widgets: PublishedWidgets? = nil) {
        let widgets = widgets ?? PublishedWidgets()
        publishedWidgets = widgets
        addMethod("widget.update", check: { params in
            _ = try Self.widgetKind(params)
            _ = try WidgetContent(params["content"])
        }, contextHandler: { params, context, reply in
            do {
                guard let notebook = context.notebook else {
                    throw DeviceCallError("denied", "widget.update: the app hasn't said which notebook this kernel runs")
                }
                widgets.publish(try WidgetContent(params["content"]), notebook: notebook, kind: try Self.widgetKind(params))
                reply(.success(NSNull()))
            } catch {
                reply(.failure(error as? DeviceCallError ?? DeviceCallError("failed", "widget.update: \(error)")))
            }
            return nil
        })
    }

    static func widgetKind(_ params: [String: Any]) throws -> String {
        guard let kind = params["kind"] as? String, (1...64).contains(kind.utf8.count),
              kind.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) })
        else {
            throw DeviceCallError("failed", "widget.update: kind must be 1 to 64 letters, digits, '.', '_' or '-'")
        }
        return kind
    }
}
