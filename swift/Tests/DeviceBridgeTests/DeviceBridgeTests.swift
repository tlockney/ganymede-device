import DeviceBridge
import XCTest

/// A date from what `Date.prototype.toISOString` writes.
private func isoDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
}

@MainActor
private final class FakeClipboard: Clipboard {
    var text: String?
    func readText() -> String? { text }
    func writeText(_ text: String) { self.text = text }
    var image: Data?
    func readImage() -> Data? { image }
    func writeImage(_ data: Data) -> Bool {
        // Stands in for the image decoder: PNG's signature, or not an image.
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return false }
        image = data
        return true
    }
}

@MainActor
private final class FakeHaptics: Haptics {
    var isAvailable = true
    var played: [String] = []
    func impact(_ style: ImpactStyle) { played.append("impact \(style.rawValue)") }
    func notification(_ type: NotificationFeedback) { played.append("notification \(type.rawValue)") }
    func selection() { played.append("selection") }
}

@MainActor
private final class FakeOpener: URLOpener {
    var opened: [(URL, Bool)] = []
    func open(_ url: URL, inApp: Bool) { opened.append((url, inApp)) }
}

@MainActor
private struct FakeState: DeviceState {
    func current() -> [String: Any] {
        ["isPad": true, "darkMode": false, "locale": "en-US", "screen": ["width": 1180.0, "height": 820.0, "scale": 2.0]]
    }
}

/// Shows nothing: records each dialog, and the test answers it.
@MainActor
private final class FakePresenter: DialogPresenter {
    var shown: [Dialog] = []
    var hosts: [DialogHost?] = []
    var closed = 0
    var refuse = false
    /// Holds each close's `gone` until `finishClosing()`, as an animation would.
    var slowClose = false
    private var closing: [() -> Void] = []
    private var answers: [(DialogResult) -> Void] = []
    func present(_ dialog: Dialog, on host: DialogHost?, done: @escaping (DialogResult) -> Void) throws -> Close {
        if refuse { throw DialogUnavailable(description: "no window") }
        shown.append(dialog)
        hosts.append(host)
        answers.append(done)
        return { [weak self] gone in
            guard let self else { return }
            self.closed += 1
            if self.slowClose { self.closing.append(gone) } else { gone() }
        }
    }
    func finishClosing() {
        let pending = closing
        closing = []
        pending.forEach { $0() }
    }
    /// Answers the newest dialog shown.
    func answer(_ result: DialogResult) {
        answers.last?(result)
    }
}

/// A dialog call's replies, as WebKit would deliver them.
@MainActor
private final class Replies {
    var all: [[String: Any]] = []
    var last: [String: Any]? { all.last }
    lazy var reply: ([String: Any]) -> Void = { [unowned self] in self.all.append($0) }
}

@MainActor
final class DeviceBridgeTests: XCTestCase {
    private func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    func testHelloListsTheMethodsItAnswers() {
        let bridge = DeviceBridge(clipboard: FakeClipboard(), appVersion: "1.2.3")
        let result = bridge.handle(["id": 1, "method": "hello", "params": [:]])["result"] as? [String: Any]
        XCTAssertEqual(result?["appVersion"] as? String, "1.2.3")
        XCTAssertEqual(
            result?["capabilities"] as? [String],
            ["clipboard.readText", "clipboard.writeText", "clipboard.readImage", "clipboard.writeImage", "info", "openURL",
             "ui.alert", "ui.confirm", "ui.prompt", "ui.actionSheet", "ui.pickDate", "share", "preview"]
                + (SystemHaptics().isAvailable
                ? ["haptics.impact", "haptics.notification", "haptics.selection"] : [])
        )
        #if os(macOS)
        XCTAssertEqual(result?["platform"] as? String, "macos")
        #endif
        XCTAssertNotNil(result?["osVersion"] as? String)
    }

    func testClipboardRoundTrip() {
        let clipboard = FakeClipboard()
        let bridge = DeviceBridge(clipboard: clipboard, appVersion: "")
        XCTAssertTrue(bridge.handle(["id": 1, "method": "clipboard.readText"])["result"] is NSNull)
        XCTAssertTrue(bridge.handle(["id": 2, "method": "clipboard.writeText", "params": ["text": "Io"]])["result"] is NSNull)
        XCTAssertEqual(clipboard.text, "Io")
        XCTAssertEqual(bridge.handle(["id": 3, "method": "clipboard.readText", "params": [:]])["result"] as? String, "Io")
    }

    func testClipboardImagesCrossAsBase64() {
        let clipboard = FakeClipboard()
        let bridge = DeviceBridge(clipboard: clipboard, appVersion: "")
        XCTAssertTrue(bridge.handle(["id": 1, "method": "clipboard.readImage"])["result"] is NSNull)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 255])
        let write = bridge.handle(["id": 2, "method": "clipboard.writeImage", "params": ["image": ["base64": png.base64EncodedString()]]])
        XCTAssertTrue(write["result"] is NSNull, "\(write)")
        XCTAssertEqual(clipboard.image, png)
        let read = bridge.handle(["id": 3, "method": "clipboard.readImage"])["result"] as? [String: Any]
        XCTAssertEqual(read?["base64"] as? String, png.base64EncodedString())
    }

    func testBadImagesFail() {
        let clipboard = FakeClipboard()
        let bridge = DeviceBridge(clipboard: clipboard, appVersion: "")
        func write(_ image: Any) -> String? {
            errorCode(bridge.handle(["id": 1, "method": "clipboard.writeImage", "params": ["image": image]]))
        }
        XCTAssertEqual(write("iVBORw=="), "failed", "a bare string isn't bytes")
        XCTAssertEqual(write(["base64": "not base64!"]), "failed")
        XCTAssertEqual(write(["base64": Data("text".utf8).base64EncodedString()]), "failed", "not an image")
        let tooBig = String(repeating: "A", count: (DeviceBridge.maxBinaryBytes / 3 + 1) * 4)
        XCTAssertEqual(write(["base64": tooBig]), "failed")
        XCTAssertNil(clipboard.image)

        clipboard.image = Data(count: DeviceBridge.maxBinaryBytes + 1)
        XCTAssertEqual(errorCode(bridge.handle(["id": 2, "method": "clipboard.readImage"])), "failed")
    }

    func testErrorsCarryProtocolCodes() {
        let bridge = DeviceBridge(clipboard: FakeClipboard(), appVersion: "")
        XCTAssertEqual(errorCode(bridge.handle(["id": 1, "method": "camera.takePhoto"])), "unavailable")
        XCTAssertEqual(errorCode(bridge.handle(["id": 2, "method": "clipboard.writeText", "params": ["text": 5]])), "failed")
        XCTAssertEqual(errorCode(bridge.handle("nonsense")), "failed")
        XCTAssertEqual(errorCode(bridge.handle(["id": 3])), "failed")
    }

    func testCancelIsAcknowledged() {
        let bridge = DeviceBridge(clipboard: FakeClipboard(), appVersion: "")
        XCTAssertNil(bridge.handle(["id": 1, "cancel": true])["error"])
    }

    func testHelloListsHapticsOnlyWhereThereAreSome() {
        let haptics = FakeHaptics()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), haptics: haptics, appVersion: "")
        XCTAssertTrue(bridge.capabilities.contains("haptics.impact"))
        haptics.isAvailable = false
        XCTAssertFalse(bridge.capabilities.contains("haptics.impact"))
        XCTAssertEqual(errorCode(bridge.handle(["id": 1, "method": "haptics.selection"])), "unavailable")
        XCTAssertEqual(haptics.played, [])
    }

    func testHapticsPlayWhatTheCellAsked() {
        let haptics = FakeHaptics()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), haptics: haptics, appVersion: "")
        XCTAssertTrue(bridge.handle(["id": 1, "method": "haptics.impact", "params": ["style": "heavy"]])["result"] is NSNull)
        XCTAssertTrue(bridge.handle(["id": 2, "method": "haptics.impact", "params": [:]])["result"] is NSNull)
        XCTAssertTrue(bridge.handle(["id": 3, "method": "haptics.notification", "params": ["type": "error"]])["result"] is NSNull)
        XCTAssertTrue(bridge.handle(["id": 4, "method": "haptics.selection"])["result"] is NSNull)
        XCTAssertEqual(haptics.played, ["impact heavy", "impact medium", "notification error", "selection"])
        XCTAssertEqual(errorCode(bridge.handle(["id": 5, "method": "haptics.impact", "params": ["style": "loud"]])), "failed")
        XCTAssertEqual(errorCode(bridge.handle(["id": 6, "method": "haptics.notification"])), "failed")
    }

    func testOpenURLTakesWebAndMailLinksOnly() {
        let opener = FakeOpener()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), urlOpener: opener, appVersion: "")
        let open = { (url: Any, inApp: Bool?) -> [String: Any] in
            var params: [String: Any] = ["url": url]
            params["inApp"] = inApp
            return bridge.handle(["id": 1, "method": "openURL", "params": params])
        }
        XCTAssertTrue(open("https://deno.com", true)["result"] is NSNull)
        XCTAssertTrue(open("HTTP://example.com", nil)["result"] is NSNull)
        XCTAssertTrue(open("mailto:a@example.com", nil)["result"] is NSNull)
        XCTAssertEqual(opener.opened.map { $0.0.absoluteString }, ["https://deno.com", "HTTP://example.com", "mailto:a@example.com"])
        XCTAssertEqual(opener.opened.map { $0.1 }, [true, false, false])
        for bad: Any in ["file:///etc/passwd", "shortcuts://run-shortcut?name=x", "not a url", 5] {
            XCTAssertEqual(errorCode(open(bad, nil)), "failed", "\(bad)")
        }
        XCTAssertEqual(opener.opened.count, 3)
    }

    func testInfoReportsTheCurrentState() {
        let bridge = DeviceBridge(clipboard: FakeClipboard(), state: FakeState(), appVersion: "")
        let result = bridge.handle(["id": 1, "method": "info"])["result"] as? [String: Any]
        XCTAssertEqual(result?["isPad"] as? Bool, true)
        XCTAssertEqual(result?["locale"] as? String, "en-US")
        XCTAssertEqual((result?["screen"] as? [String: Any])?["scale"] as? Double, 2.0)
    }

    func testSystemStateIsPlainValues() throws {
        // What WebKit can carry: the reply must be a property list.
        let state = SystemDeviceState().current()
        XCTAssertNotNil(state["locale"] as? String)
        XCTAssertNotNil(state["darkMode"] as? Bool)
        XCTAssertNotNil(state["isPad"] as? Bool)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(state))
    }

    func testHelloNamesTheModel() {
        let bridge = DeviceBridge(clipboard: FakeClipboard(), appVersion: "")
        let result = bridge.handle(["id": 1, "method": "hello"])["result"] as? [String: Any]
        XCTAssertFalse((result?["model"] as? String ?? "").isEmpty)
    }

    func testDialogsAnswerWithWhatThePersonChose() {
        let presenter = FakePresenter()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), presenter: presenter, appVersion: "")
        let replies = Replies()
        func ask(_ id: Int, _ method: String, _ params: [String: Any]) {
            bridge.respond(to: ["id": id, "method": method, "params": params], reply: replies.reply)
        }

        ask(1, "ui.alert", ["message": "Done"])
        XCTAssertEqual(presenter.shown.last, .alert(title: nil, message: "Done"))
        XCTAssertTrue(replies.all.isEmpty, "a dialog answers only once it closes")
        presenter.answer(.ok)
        XCTAssertTrue(replies.last?["result"] is NSNull)

        ask(2, "ui.confirm", ["message": "Delete?", "destructive": true])
        XCTAssertEqual(presenter.shown.last, .confirm(title: nil, message: "Delete?", destructive: true, okLabel: nil))
        presenter.answer(.confirmed)
        XCTAssertEqual(replies.last?["result"] as? Bool, true)
        ask(3, "ui.confirm", ["message": "Delete?"])
        presenter.answer(.dismissed)
        XCTAssertEqual(replies.last?["result"] as? Bool, false)

        ask(4, "ui.prompt", ["message": "Name?", "placeholder": "Alex", "secure": true])
        XCTAssertEqual(presenter.shown.last, .prompt(title: nil, message: "Name?", placeholder: "Alex", defaultValue: nil, secure: true))
        presenter.answer(.text("Io"))
        XCTAssertEqual(replies.last?["result"] as? String, "Io")
        ask(5, "ui.prompt", ["message": "Name?"])
        presenter.answer(.dismissed)
        XCTAssertTrue(replies.last?["result"] is NSNull)

        ask(6, "ui.actionSheet", ["title": "Quality", "options": ["Low", "High"], "destructive": 1])
        XCTAssertEqual(presenter.shown.last, .actionSheet(title: "Quality", message: nil, options: ["Low", "High"], cancel: nil, destructive: 1))
        presenter.answer(.option(1))
        XCTAssertEqual(replies.last?["result"] as? Int, 1)

        let min = isoDate("2026-01-01T00:00:00.000Z")!
        ask(7, "ui.pickDate", ["mode": "date", "min": "2026-01-01T00:00:00.000Z"])
        XCTAssertEqual(presenter.shown.last, .pickDate(title: nil, mode: .date, value: nil, min: min, max: nil))
        presenter.answer(.date(isoDate("2026-11-04T20:30:00.250Z")!))
        XCTAssertEqual(replies.last?["result"] as? String, "2026-11-04T20:30:00.250Z")
        XCTAssertEqual(replies.all.count, 7)
        XCTAssertTrue(replies.all.allSatisfy { JSONSerialization.isValidJSONObject($0) })
    }

    func testOneDialogAtATime() {
        let presenter = FakePresenter()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), presenter: presenter, appVersion: "")
        let first = Replies()
        let second = Replies()
        bridge.respond(to: ["id": 1, "method": "ui.alert", "params": ["message": "one"]], reply: first.reply)
        bridge.respond(to: ["id": 2, "method": "ui.alert", "params": ["message": "two"]], reply: second.reply)
        XCTAssertEqual(presenter.shown.count, 1, "the second waits for the first")
        presenter.answer(.ok)
        XCTAssertEqual(first.all.count, 1)
        XCTAssertEqual(presenter.shown.last, .alert(title: nil, message: "two"))
        presenter.answer(.ok)
        XCTAssertEqual(second.all.count, 1)
        presenter.answer(.ok)
        XCTAssertEqual(first.all.count + second.all.count, 2, "a second answer to a closed dialog is dropped")
    }

    func testCancelClosesTheDialogOrTakesItOffTheQueue() {
        let presenter = FakePresenter()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), presenter: presenter, appVersion: "")
        let shown = Replies()
        let queued = Replies()
        let next = Replies()
        bridge.respond(to: ["id": 1, "method": "ui.prompt", "params": ["message": "a"]], reply: shown.reply)
        bridge.respond(to: ["id": 2, "method": "ui.prompt", "params": ["message": "b"]], reply: queued.reply)
        bridge.respond(to: ["id": 3, "method": "ui.prompt", "params": ["message": "c"]], reply: next.reply)

        XCTAssertNil(bridge.handle(["id": 2, "cancel": true])["error"])
        XCTAssertEqual(errorCode(queued.last ?? [:]), "cancelled")
        XCTAssertEqual(presenter.closed, 0, "a queued dialog was never shown")

        _ = bridge.handle(["id": 1, "cancel": true])
        XCTAssertEqual(presenter.closed, 1)
        XCTAssertEqual(errorCode(shown.last ?? [:]), "cancelled")
        XCTAssertEqual(presenter.shown.map { $0 }, [
            .prompt(title: nil, message: "a", placeholder: nil, defaultValue: nil, secure: false),
            .prompt(title: nil, message: "c", placeholder: nil, defaultValue: nil, secure: false),
        ], "the next waiting dialog shows")
        _ = bridge.handle(["id": 99, "cancel": true])
        XCTAssertTrue(next.all.isEmpty, "a cancel for another id leaves it alone")
    }

    func testTheNextDialogWaitsForTheCancelledOneToGo() {
        let presenter = FakePresenter()
        presenter.slowClose = true
        let bridge = DeviceBridge(clipboard: FakeClipboard(), presenter: presenter, appVersion: "")
        let first = Replies()
        let second = Replies()
        bridge.respond(to: ["id": 1, "method": "ui.alert", "params": ["message": "one"]], reply: first.reply)
        bridge.respond(to: ["id": 2, "method": "ui.alert", "params": ["message": "two"]], reply: second.reply)
        _ = bridge.handle(["id": 1, "cancel": true])
        XCTAssertEqual(errorCode(first.last ?? [:]), "cancelled", "the cancel answers at once")
        XCTAssertEqual(presenter.shown.count, 1, "the second waits while the first goes away")
        _ = bridge.handle(["id": 1, "cancel": true])
        XCTAssertEqual(presenter.closed, 1, "a second cancel doesn't close it again")
        presenter.answer(.ok)
        XCTAssertEqual(first.all.count, 1, "a late answer is dropped")
        presenter.finishClosing()
        XCTAssertEqual(presenter.shown.last, .alert(title: nil, message: "two"))
        presenter.answer(.ok)
        XCTAssertEqual(second.all.count, 1)
    }

    func testDropAllClosesEverything() {
        let presenter = FakePresenter()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), presenter: presenter, appVersion: "")
        let replies = Replies()
        bridge.respond(to: ["id": 1, "method": "ui.alert", "params": ["message": "a"]], reply: replies.reply)
        bridge.respond(to: ["id": 2, "method": "ui.alert", "params": ["message": "b"]], reply: replies.reply)
        bridge.dropAll()
        XCTAssertEqual(presenter.closed, 1)
        XCTAssertEqual(replies.all.compactMap { errorCode($0) }, ["cancelled", "cancelled"])
        XCTAssertEqual(presenter.shown.count, 1)
        presenter.answer(.ok)
        XCTAssertEqual(replies.all.count, 2)
    }

    func testADialogShowsOnThePageThatAsked() {
        let presenter = FakePresenter()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), presenter: presenter, appVersion: "")
        let page = DialogHost()
        bridge.respond(to: ["id": 1, "method": "ui.alert", "params": ["message": "m"]], from: page) { _ in }
        XCTAssertTrue(presenter.hosts.last! === page)
    }

    func testAnActionSheetsDestructiveIsAnIndex() throws {
        let sheet = { (destructive: Any) in
            try Dialog(method: "ui.actionSheet", params: ["title": "t", "options": ["a", "b"], "destructive": destructive])
        }
        XCTAssertEqual(try sheet(NSNumber(value: 1)), .actionSheet(title: "t", message: nil, options: ["a", "b"], cancel: nil, destructive: 1))
        XCTAssertEqual(try sheet(NSNumber(value: true)), .actionSheet(title: "t", message: nil, options: ["a", "b"], cancel: nil, destructive: nil))
    }

    func testBadDialogsFail() {
        let presenter = FakePresenter()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), presenter: presenter, appVersion: "")
        let replies = Replies()
        let bad: [[String: Any]] = [
            ["id": 1, "method": "ui.alert", "params": [:]],
            ["id": 2, "method": "ui.actionSheet", "params": ["title": "t", "options": []]],
            ["id": 3, "method": "ui.pickDate", "params": ["mode": "week"]],
            ["id": 4, "method": "ui.pickDate", "params": ["min": "yesterday"]],
            ["method": "ui.alert", "params": ["message": "no id"]],
            ["id": 1e300, "method": "ui.alert", "params": ["message": "id too big"]],
            ["id": Double.infinity, "method": "ui.alert", "params": ["message": "id not finite"]],
        ]
        for call in bad {
            bridge.respond(to: call, reply: replies.reply)
            XCTAssertEqual(errorCode(replies.last ?? [:]), "failed", "\(call)")
        }
        XCTAssertTrue(presenter.shown.isEmpty)
        XCTAssertEqual(errorCode(bridge.handle(["id": 5, "method": "ui.alert", "params": ["message": "m"]])), "failed")

        presenter.refuse = true
        bridge.respond(to: ["id": 6, "method": "ui.alert", "params": ["message": "m"]], reply: replies.reply)
        XCTAssertEqual(errorCode(replies.last ?? [:]), "unavailable")
        presenter.refuse = false
        bridge.respond(to: ["id": 7, "method": "ui.alert", "params": ["message": "m"]], reply: replies.reply)
        XCTAssertEqual(presenter.shown.count, 1, "a refused dialog doesn't block the next")
    }

    func testShareAndPreviewShowAsSheets() {
        let presenter = FakePresenter()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), presenter: presenter, appVersion: "")
        let replies = Replies()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let file: [String: Any] = ["name": "plot.png", "data": ["base64": png.base64EncodedString()]]
        XCTAssertTrue(bridge.capabilities.contains("share") && bridge.capabilities.contains("preview"))

        bridge.respond(
            to: ["id": 1, "method": "share", "params": ["text": "hi", "url": "https://deno.com/", "files": [file]]],
            reply: replies.reply
        )
        XCTAssertEqual(
            presenter.shown.last,
            .share(text: "hi", url: URL(string: "https://deno.com/"), files: [NamedFile(name: "plot.png", data: png)])
        )
        XCTAssertTrue(replies.all.isEmpty, "a sheet answers only once it closes")
        presenter.answer(.shared)
        XCTAssertEqual(replies.last?["result"] as? Bool, true)

        bridge.respond(to: ["id": 2, "method": "share", "params": ["text": "hi", "files": []]], reply: replies.reply)
        XCTAssertEqual(presenter.shown.last, .share(text: "hi", url: nil, files: []))
        presenter.answer(.dismissed)
        XCTAssertEqual(replies.last?["result"] as? Bool, false, "a dismissed share sheet is false, not an error")

        bridge.respond(to: ["id": 3, "method": "preview", "params": ["files": [file, file]]], reply: replies.reply)
        XCTAssertEqual(presenter.shown.last, .preview(files: Array(repeating: NamedFile(name: "plot.png", data: png), count: 2)))
        presenter.answer(.dismissed)
        XCTAssertTrue(replies.last?["result"] is NSNull)
        XCTAssertEqual(replies.all.count, 3)
    }

    func testBadSharesAndPreviewsFail() {
        let presenter = FakePresenter()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), presenter: presenter, appVersion: "")
        let replies = Replies()
        let data: [String: Any] = ["base64": "AQ=="]
        let bad: [[String: Any]] = [
            ["id": 1, "method": "share", "params": [:]],
            ["id": 2, "method": "share", "params": ["url": "not a url"]],
            ["id": 3, "method": "share", "params": ["files": [["name": "a/b", "data": data]]]],
            ["id": 4, "method": "share", "params": ["files": [["name": "..", "data": data]]]],
            ["id": 5, "method": "share", "params": ["files": [["name": "a", "data": ["base64": "!!"]]]]],
            ["id": 6, "method": "preview", "params": ["files": []]],
            ["id": 7, "method": "preview", "params": ["files": "x"]],
        ]
        for call in bad {
            bridge.respond(to: call, reply: replies.reply)
            XCTAssertEqual(errorCode(replies.last ?? [:]), "failed", "\(call)")
        }
        XCTAssertTrue(presenter.shown.isEmpty)
        XCTAssertTrue(NamedFile.isPlainName("report 1.pdf"))
        XCTAssertFalse(NamedFile.isPlainName(" "))
    }

    func testOtherMethodsStillAnswerThroughRespond() {
        let replies = Replies()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), presenter: FakePresenter(), appVersion: "")
        bridge.respond(to: ["id": 1, "method": "clipboard.writeText", "params": ["text": "x"]], reply: replies.reply)
        XCTAssertTrue(replies.last?["result"] is NSNull)
        bridge.respond(to: ["id": 2, "method": "ui.unknown"], reply: replies.reply)
        XCTAssertEqual(errorCode(replies.last ?? [:]), "unavailable")
    }
}
