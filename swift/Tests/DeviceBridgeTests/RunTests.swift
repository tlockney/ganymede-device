@testable import DeviceBridge
import XCTest

/// Widgets in memory, counting reloads.
@MainActor
final class MemoryWidgetStore: WidgetStore {
    var saved: [PublishedWidget] = []
    var reloads = 0
    func load() -> [PublishedWidget] { saved }
    func save(_ widgets: [PublishedWidget]) { saved = widgets }
    func reload() { reloads += 1 }
}

/// A run's input and output, and `widget.update` (docs/phase-4.md,
/// parts 3 to 5).
@MainActor
final class RunTests: XCTestCase {
    private var bridge: DeviceBridge!
    private var widgets: MemoryWidgetStore!

    override func setUp() async throws {
        widgets = MemoryWidgetStore()
        bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.addWidgets(PublishedWidgets(store: widgets))
    }

    private func send(_ engine: EngineDevice, _ message: [String: Any]) -> [String: Any]? {
        var reply: [String: Any]?
        let text = String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
        engine.respond(to: text) { reply = try! JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return reply
    }

    private func code(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["code"] as? String
    }

    private func capabilities(_ engine: EngineDevice) -> [String] {
        (send(engine, ["id": 1, "method": "hello", "params": [:]])?["result"] as? [String: Any])?["capabilities"] as? [String] ?? []
    }

    func testARunHasInputAndOutput() throws {
        let engine = bridge.engineDevice(headless: true)
        var outputs: [RunOutput] = []
        engine.attachRun(RunInput(text: "hi", url: URL(string: "https://example.com/"), files: [RunFile(name: "p.png", type: "image/png", data: Data([1, 2]))])) {
            outputs.append($0)
        }
        XCTAssertTrue(capabilities(engine).contains("input"))
        XCTAssertTrue(capabilities(engine).contains("output"))
        let input = try XCTUnwrap(send(engine, ["id": 2, "method": "input", "params": [:]])?["result"] as? [String: Any])
        XCTAssertEqual(input["text"] as? String, "hi")
        XCTAssertEqual(input["url"] as? String, "https://example.com/")
        let file = try XCTUnwrap((input["files"] as? [[String: Any]])?.first)
        XCTAssertEqual(file["type"] as? String, "image/png")
        XCTAssertEqual((file["data"] as? [String: Any])?["base64"] as? String, "AQI=")

        let sent = send(engine, ["id": 3, "method": "output", "params": ["text": "done", "files": [["name": "a.txt", "data": ["base64": "AQI="]]]]])
        XCTAssertTrue(sent?["result"] is NSNull)
        XCTAssertEqual(outputs, [RunOutput(text: "done", files: [RunFile(name: "a.txt", data: Data([1, 2]))])])
        XCTAssertEqual(code(send(engine, ["id": 4, "method": "output", "params": [:]])), "failed")
        XCTAssertEqual(code(send(engine, ["id": 5, "method": "output", "params": ["files": [["name": "a/b", "data": ["base64": ""]]]]])), "failed")
        XCTAssertEqual(outputs.count, 1)
    }

    func testANotebookContextHasNeither() {
        let engine = bridge.engineDevice()
        XCTAssertFalse(capabilities(engine).contains("input"))
        XCTAssertEqual(code(send(engine, ["id": 2, "method": "input", "params": [:]])), "unavailable")
        XCTAssertEqual(code(send(engine, ["id": 3, "method": "output", "params": ["text": "a"]])), "unavailable")
        var reply: [String: Any]?
        bridge.respond(to: ["id": 1, "owner": 1, "method": "output", "params": ["text": "a"]]) { reply = $0 }
        XCTAssertEqual(code(reply), "unavailable", "the page has no run either")
    }

    func testAWidgetUpdateIsKeptPerNotebookAndKind() throws {
        bridge.setNotebook("/n/A.ipynb", for: 1)
        bridge.setNotebook("/n/B.ipynb", for: 2)
        let content: [String: Any] = ["title": "Oslo", "rows": [["label": "Now", "value": 4, "unit": "°C"], ["text": "Rain"]], "tint": "blue", "sparkline": [1, 2.5]]
        for owner in [1, 2] {
            var reply: [String: Any]?
            bridge.respond(to: ["id": 1, "owner": owner, "method": "widget.update", "params": ["kind": "weather", "content": content]]) { reply = $0 }
            XCTAssertTrue(reply?["result"] is NSNull)
        }
        bridge.respond(to: ["id": 2, "owner": 1, "method": "widget.update", "params": ["kind": "weather", "content": ["title": "Bergen"]]]) { _ in }
        let published = PublishedWidgets(store: widgets)
        XCTAssertEqual(published.content(notebook: "/n/A.ipynb", kind: "weather")?.title, "Bergen", "replaced")
        let b = try XCTUnwrap(published.content(notebook: "/n/B.ipynb", kind: "weather"))
        XCTAssertEqual(b.rows.first?.value, 4)
        XCTAssertEqual(b.rows.last?.text, "Rain")
        XCTAssertEqual(b.sparkline, [1, 2.5])
        XCTAssertEqual(widgets.saved.count, 2)
        XCTAssertEqual(widgets.reloads, 3)
        bridge.notebookMoved(from: "/n/A.ipynb", to: "/n/C.ipynb")
        XCTAssertEqual(published.content(notebook: "/n/C.ipynb", kind: "weather")?.title, "Bergen")
    }

    func testBadWidgetsFail() {
        bridge.setNotebook("/n/A.ipynb", for: 1)
        let bad: [[String: Any]] = [
            ["kind": "", "content": [:]],
            ["kind": "a b", "content": [:]],
            ["kind": "a", "content": "x"],
            ["kind": "a", "content": ["title": String(repeating: "x", count: 65)]],
            ["kind": "a", "content": ["rows": Array(repeating: ["text": "a"], count: 7)]],
            ["kind": "a", "content": ["rows": [["value": "4"]]]],
            ["kind": "a", "content": ["rows": [["value": true]]]],
            ["kind": "a", "content": ["rows": [[:]]]],
            ["kind": "a", "content": ["tint": "chartreuse"]],
            ["kind": "a", "content": ["sparkline": Array(repeating: 1, count: 65)]],
        ]
        for params in bad {
            var reply: [String: Any]?
            bridge.respond(to: ["id": 1, "owner": 1, "method": "widget.update", "params": params]) { reply = $0 }
            XCTAssertEqual(code(reply), "failed", "\(params)")
        }
        XCTAssertTrue(widgets.saved.isEmpty)
        var reply: [String: Any]?
        bridge.respond(to: ["id": 1, "owner": 3, "method": "widget.update", "params": ["kind": "a", "content": [:]]]) { reply = $0 }
        XCTAssertEqual(code(reply), "denied", "no notebook")
    }

    func testEachNotebookKeepsItsNewest() {
        let published = PublishedWidgets(store: widgets)
        published.publish(try! WidgetContent(["title": "b"]), notebook: "/n/B.ipynb", kind: "b", at: Date(timeIntervalSince1970: 0))
        for n in 1...(PublishedWidgets.limit + 3) {
            published.publish(try! WidgetContent(["title": "\(n)"]), notebook: "/n/A.ipynb", kind: "k\(n)", at: Date(timeIntervalSince1970: Double(n)))
        }
        XCTAssertEqual(widgets.saved.count, PublishedWidgets.limit + 1)
        XCTAssertNotNil(published.content(notebook: "/n/B.ipynb", kind: "b"), "another notebook's stays")
        XCTAssertEqual(published.all.first?.kind, "k\(PublishedWidgets.limit + 3)")
        XCTAssertNil(published.content(notebook: "/n/A.ipynb", kind: "k1"))
    }
}
