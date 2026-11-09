import Foundation
import UniformTypeIdentifiers
import WebKit
#if os(macOS)
import AppKit
import IOKit.ps
#else
import SafariServices
import UIKit
#endif

/// The app's answer to `device` calls from notebook cells (docs/protocol.md):
/// a WebKit message handler with replies, named `device`. Register it only
/// on the web view that runs kernels, never on one that renders notebook
/// outputs, so outputs can't reach it.
@MainActor
public final class DeviceBridge: NSObject, WKScriptMessageHandlerWithReply {
    /// The name `webkitHost()` posts to.
    public static let handlerName = "device"

    private let clipboard: Clipboard
    private let haptics: Haptics
    private let urlOpener: URLOpener
    private let state: DeviceState
    private let dialogs: DialogQueue
    private let sounds: Sounds
    private let streams = Streams()
    /// Each namespace's system permission (`addPermission`).
    private var permissions: [String: Permission] = [:]
    /// Methods that answer later (`addMethod`), with the namespace whose permission they need.
    private var methods: [String: (permission: String?, handler: MethodHandler)] = [:]
    /// The namespace whose permission each streaming method needs.
    private var streamPermissions: [String: String] = [:]
    private let pending = PendingCalls()
    private let requests = PermissionRequests()
    private let ledgerRequests = LedgerRequests()
    private let appVersion: String

    public init(
        clipboard: Clipboard? = nil,
        haptics: Haptics? = nil,
        urlOpener: URLOpener? = nil,
        state: DeviceState? = nil,
        presenter: DialogPresenter? = nil,
        sounds: SoundLoader? = nil,
        ledger: PermissionLedger? = nil,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    ) {
        // Made here, not as the default arguments: defaults are evaluated
        // outside the main actor.
        self.clipboard = clipboard ?? SystemClipboard()
        self.haptics = haptics ?? SystemHaptics()
        self.urlOpener = urlOpener ?? SystemURLOpener()
        self.state = state ?? SystemDeviceState()
        self.dialogs = DialogQueue(presenter: presenter ?? SystemDialogPresenter())
        self.sounds = Sounds(loader: sounds ?? SystemSoundLoader())
        self.ledger = ledger ?? PermissionLedger()
        self.appVersion = appVersion
    }

    /// The app's permission ledger: kept answers, for a Settings screen to
    /// list and revoke, and the notebook each kernel runs.
    public let ledger: PermissionLedger

    /// Shows the app's permission prompt. Without one (headless runs), a
    /// permissioned call with no kept "always" is denied.
    public weak var ledgerPrompter: LedgerPrompter?

    /// Kernel `owner` (its `webkitHost().owner`) runs the notebook at
    /// `path`; call it when the kernel starts and when the notebook is
    /// renamed or moved (or use `notebookMoved`). Permissioned calls from a
    /// kernel with no notebook are denied.
    public func setNotebook(_ path: String?, for owner: Int) {
        ledger.setNotebook(path, for: owner)
    }

    /// A notebook was renamed or moved: its kernels and kept answers follow.
    public func notebookMoved(from old: String, to new: String) {
        ledger.move(from: old, to: new)
    }

    /// Of a notebook's declared capabilities (`metadata.ganymede.device`),
    /// the ones this app has and the ledger has no answer for, so the app
    /// can ask when the notebook opens.
    public func undecided(_ declared: [String], notebook: String) -> [String] {
        ledger.undecided(declared.filter { permissions[$0] != nil }, notebook: notebook)
    }

    /// Adds a streaming method (docs/protocol.md, "Streams"): `hello` lists
    /// it, a call to it runs `start` and answers `{ stream }`, and the page
    /// reads the values with `stream.next`. The queue keeps the newest
    /// `capacity` values and counts the ones it drops.
    /// With `permission`, a namespace added with `addPermission`, a call
    /// asks for it first (docs/protocol.md, "Permissions").
    public func addStream(_ method: String, capacity: Int = 64, permission: String? = nil, start: @escaping StreamStarter) {
        streams.add(method, capacity: capacity, start: start)
        streamPermissions[method] = permission
    }

    /// Adds `namespace`'s system permission: `hello` lists
    /// `<namespace>.authorizationStatus` and
    /// `<namespace>.requestAuthorization`, and methods added with
    /// `permission: namespace` ask for it lazily.
    public func addPermission(_ namespace: String, _ permission: Permission) {
        permissions[namespace] = permission
    }

    /// Adds a method that answers later, such as a sensor read. With
    /// `permission`, a namespace added with `addPermission`, the call asks
    /// for it first and rejects `denied` without a grant. A cancel rejects
    /// the call `cancelled` and runs the cancel action `handler` returned.
    public func addMethod(_ method: String, permission: String? = nil, handler: @escaping MethodHandler) {
        methods[method] = (permission, handler)
    }

    /// Adds the bridge to `controller`, in the page's content world.
    public func register(in controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
    }

    public func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        // The kernel page has no frames of its own; anything else posting
        // here is not the kernel host.
        guard message.frameInfo.isMainFrame else {
            replyHandler(Self.error("unavailable", "device calls are taken from the kernel page only"), nil)
            return
        }
        respond(to: message.body, from: message.webView) { replyHandler($0, nil) }
    }

    /// Answers one message, now or, for a dialog, once the person closes
    /// it. `reply` is called once. A dialog shows on `host`'s window, the
    /// notebook whose page asked, or on the key window without one.
    public func respond(to body: Any, from host: DialogHost? = nil, reply: @escaping ([String: Any]) -> Void) {
        if let call = body as? [String: Any], call["method"] as? String == "stream.next" {
            streams.next(
                call["params"] as? [String: Any] ?? [:], call: Self.callID(call["id"]),
                owner: Self.callID(call["owner"]) ?? 0, reply: reply)
            return
        }
        if let call = body as? [String: Any], let method = call["method"] as? String, answersLater(method) {
            respondLater(method, call, reply: reply)
            return
        }
        guard let call = body as? [String: Any], let method = call["method"] as? String,
              Self.dialogMethods.contains(method)
        else {
            reply(handle(body))
            return
        }
        guard let id = Self.callID(call["id"]) else {
            reply(Self.error("failed", "a dialog call needs a numeric id, so it can be cancelled"))
            return
        }
        let dialog: Dialog
        do {
            dialog = try Dialog(method: method, params: call["params"] as? [String: Any] ?? [:])
        } catch {
            reply(Self.error("failed", "\(error)"))
            return
        }
        dialogs.show(dialog, id: id, on: host) { outcome in
            switch outcome {
            case let .answered(result):
                reply(["result": result])
            case .cancelled:
                reply(Self.error("cancelled", "\(method) was cancelled"))
            case let .failed(code, message):
                reply(Self.error(code, message))
            }
        }
    }

    /// Closes every dialog shown or waiting and stops every sound, as when the kernel page
    /// navigates or its web content process ends (docs/protocol.md): the
    /// new page's ids start over, so none of them may be answered. Call it
    /// from the web view's navigation delegate.
    public func dropAll() {
        dialogs.drop { _ in true }
        sounds.stop { _ in true }
        streams.stop { _ in true }
        cancelPending { _ in true }
        ledger.forget { _ in true }
    }

    /// Closes the kernel page's dialogs and stops its sounds, as `dropAll()`
    /// does, and leaves the remote handler's (`registerRemote`) alone: the
    /// kernel page navigated or its process ended, but the UI page that
    /// answers server kernels is still there.
    public func dropPage() {
        dialogs.drop { $0 > 0 }
        sounds.stop { $0 >= 0 }
        streams.stop { $0 >= 0 }
        cancelPending { $0 >= 0 }
        ledger.forget { $0 >= 0 }
    }

    /// Closes the remote handler's dialogs and stops its sounds, and leaves
    /// the kernel page's alone: the UI page that answers server kernels
    /// navigated or its process ended.
    public func dropRemote() {
        dialogs.drop { $0 < 0 }
        sounds.stop { $0 < 0 }
        streams.stop { $0 < 0 }
        cancelPending { $0 < 0 }
        ledger.forget { $0 < 0 }
    }

    /// One message's reply: `{ result }` or `{ error: { code, message } }`.
    /// Dialogs (`ui.*`) answer later, so they go through
    /// `respond(to:reply:)`; here they fail `failed`.
    public func handle(_ body: Any) -> [String: Any] {
        guard let call = body as? [String: Any] else {
            return Self.error("failed", "a device message must be an object")
        }
        let owner = Self.callID(call["owner"]) ?? 0
        if call["release"] as? Bool == true {
            // The kernel behind this handler shut down.
            sounds.release(owner)
            streams.stop { $0 == owner }
            cancelPending { $0 == owner }
            ledger.forget { $0 == owner }
            return ["result": NSNull()]
        }
        if call["cancel"] as? Bool == true {
            // Closes the dialog the call showed, or takes it off the queue,
            // or closes the player it opened.
            if let id = Self.callID(call["id"]) {
                dialogs.cancel(id)
                sounds.cancel(id)
                ledgerRequests.cancel(id, prompter: ledgerPrompter)
                pending.cancel(id)
                streams.cancel(id)
            }
            return ["result": NSNull()]
        }
        guard let method = call["method"] as? String else {
            return Self.error("failed", "a device call needs a method")
        }
        let params = call["params"] as? [String: Any] ?? [:]
        switch method {
        case "hello":
            // Each Worker says hello once, when it starts: anything an
            // earlier Worker of this kernel opened has no handle left.
            if owner != 0 {
                sounds.release(owner)
                streams.stop { $0 == owner }
                cancelPending { $0 == owner }
            }
            return ["result": hello()]
        case "clipboard.readText":
            return ["result": clipboard.readText() ?? NSNull()]
        case "clipboard.writeText":
            guard let text = params["text"] as? String else {
                return Self.error("failed", "clipboard.writeText needs a text string")
            }
            clipboard.writeText(text)
            return ["result": NSNull()]
        case "clipboard.readImage":
            guard let png = clipboard.readImage() else { return ["result": NSNull()] }
            return Self.binaryResult(png)
        case "clipboard.writeImage":
            let image: Data
            do {
                image = try Self.bytes(params["image"])
            } catch {
                return Self.error("failed", "clipboard.writeImage: \(error)")
            }
            guard clipboard.writeImage(image) else {
                return Self.error("failed", "clipboard.writeImage takes PNG, JPEG, GIF, HEIC or TIFF bytes")
            }
            return ["result": NSNull()]
        case "info":
            return ["result": state.current()]
        case "openURL":
            return openURL(params)
        case "haptics.impact", "haptics.notification", "haptics.selection":
            guard haptics.isAvailable else {
                return Self.error("unavailable", "this device has no haptics")
            }
            return haptic(method, params)
        case "sound.play", "sound.player", "sound.control", "sound.close":
            return sounds.handle(method, params, call: Self.callID(call["id"]), owner: owner)
        case "stream.next":
            return Self.error("failed", "stream.next answers later; send it through respond(to:reply:)")
        case "stream.close":
            return streams.close(params, owner: owner)
        case _ where answersLater(method):
            return Self.error("failed", "\(method) answers later; send it through respond(to:reply:)")
        case _ where method.hasSuffix(".authorizationStatus"):
            guard let permission = permissions[String(method.dropLast(".authorizationStatus".count))] else {
                return Self.error("unavailable", "\(method) isn't available in this app")
            }
            return ["result": permission.status.rawValue]
        case _ where streams.methods[method] != nil:
            return streams.start(method, params, call: Self.callID(call["id"]), owner: owner)
        case _ where Self.dialogMethods.contains(method):
            return Self.error("failed", "\(method) answers later; send it through respond(to:reply:)")
        default:
            return Self.error("unavailable", "\(method) isn't available in this app")
        }
    }

    /// A call's `id`: the page sends a number, which WebKit hands over as
    /// an NSNumber.
    static func callID(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(exactly: n) }
        return nil
    }

    /// The methods every bridge answers. `capabilities` adds what this
    /// device has.
    public static let capabilities = [
        "clipboard.readText", "clipboard.writeText", "clipboard.readImage", "clipboard.writeImage", "info", "openURL",
        "ui.alert", "ui.confirm", "ui.prompt", "ui.actionSheet", "ui.pickDate", "share", "preview",
        "files.pick", "files.export", "photos.pick", "sound.play", "sound.player", "sound.control", "sound.close",
    ]

    /// The methods that show a dialog or sheet and answer once it closes.
    public static let dialogMethods: Set<String> = [
        "ui.alert", "ui.confirm", "ui.prompt", "ui.actionSheet", "ui.pickDate", "share", "preview",
        "files.pick", "files.export", "photos.pick",
    ]

    /// The methods this bridge answers, as `hello` reports them.
    public var capabilities: [String] {
        Self.capabilities + (haptics.isAvailable ? ["haptics.impact", "haptics.notification", "haptics.selection"] : [])
            + permissions.keys.sorted().flatMap { ["\($0).authorizationStatus", "\($0).requestAuthorization"] }
            // A method whose namespace has no `addPermission` would only fail
            // `unavailable`, so `has()` mustn't report it.
            + methods.filter { $0.value.permission.map { permissions[$0] != nil } ?? true }.keys.sorted()
            + streams.methods.keys.filter { streamPermissions[$0].map { permissions[$0] != nil } ?? true }.sorted()
    }

    private func hello() -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var reply: [String: Any] = [
            "platform": Self.platform,
            "appVersion": appVersion,
            "osVersion": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "capabilities": capabilities,
        ]
        reply["model"] = Self.model
        return reply
    }

    /// The schemes `openURL` opens: web pages and mail, nothing that
    /// starts another app with arguments a cell chose.
    public static let urlSchemes: Set<String> = ["http", "https", "mailto"]

    private func openURL(_ params: [String: Any]) -> [String: Any] {
        guard let text = params["url"] as? String, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), Self.urlSchemes.contains(scheme)
        else {
            return Self.error("failed", "openURL takes an http, https or mailto URL")
        }
        urlOpener.open(url, inApp: params["inApp"] as? Bool ?? false)
        return ["result": NSNull()]
    }

    private func haptic(_ method: String, _ params: [String: Any]) -> [String: Any] {
        switch method {
        case "haptics.impact":
            guard let style = ImpactStyle(rawValue: params["style"] as? String ?? "medium") else {
                return Self.error("failed", "haptics.impact takes light, medium, heavy, soft or rigid")
            }
            haptics.impact(style)
        case "haptics.notification":
            guard let type = NotificationFeedback(rawValue: params["type"] as? String ?? "") else {
                return Self.error("failed", "haptics.notification takes success, warning or error")
            }
            haptics.notification(type)
        default:
            haptics.selection()
        }
        return ["result": NSNull()]
    }

    // MARK: Calls that answer later

    /// `<namespace>.requestAuthorization`, an `addMethod` method, or a
    /// streaming method that needs a permission.
    private func answersLater(_ method: String) -> Bool {
        methods[method] != nil || streamPermissions[method] != nil || requestedNamespace(method) != nil
    }

    /// The namespace `method` requests authorization for, when it is one
    /// added with `addPermission`.
    private func requestedNamespace(_ method: String) -> String? {
        let suffix = ".requestAuthorization"
        guard method.hasSuffix(suffix) else { return nil }
        let namespace = String(method.dropLast(suffix.count))
        return permissions[namespace] == nil ? nil : namespace
    }

    private func respondLater(_ method: String, _ call: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let id = Self.callID(call["id"]) else {
            reply(Self.error("failed", "\(method) needs a numeric call id, so it can be cancelled"))
            return
        }
        let owner = Self.callID(call["owner"]) ?? 0
        guard let token = pending.begin(id, owner: owner, reply: reply) else {
            reply(Self.error("failed", "call \(id) is already waiting"))
            return
        }
        let params = call["params"] as? [String: Any] ?? [:]
        if let namespace = requestedNamespace(method), let permission = permissions[namespace] {
            // The ledger first: a notebook it refuses gets `denied` without
            // the system prompt.
            checkLedger(method, namespace, call: token, owner: owner, refused: { [weak self] _ in
                self?.pending.answer(token, ["result": PermissionStatus.denied.rawValue])
            }, allowed: { [weak self] in
                self?.requests.request(permission) { [weak self] status in
                    self?.pending.answer(token, ["result": status.rawValue])
                }
            })
        } else if let entry = methods[method] {
            authorize(method, entry.permission, call: token, owner: owner) { [weak self] in
                self?.run(entry.handler, params, call: token)
            }
        } else {
            authorize(method, streamPermissions[method], call: token, owner: owner) { [weak self] in
                guard let self else { return }
                self.pending.answer(token, self.streams.start(method, params, call: token.id, owner: owner))
            }
        }
    }

    /// Runs `proceed` once `namespace`'s permission is granted, asking the
    /// system when it hasn't been asked; otherwise rejects `token`
    /// `denied`. Nothing happens for a call cancelled meanwhile.
    private func authorize(_ method: String, _ namespace: String?, call token: PendingCall, owner: Int, then proceed: @escaping @MainActor () -> Void) {
        guard let namespace else {
            proceed()
            return
        }
        guard let permission = permissions[namespace] else {
            pending.answer(token, Self.error("unavailable", "\(method) needs the \(namespace) permission, which this app doesn't have"))
            return
        }
        checkLedger(method, namespace, call: token, owner: owner, refused: { [weak self] message in
            self?.pending.answer(token, Self.error("denied", message))
        }, allowed: { [weak self] in
            self?.askSystem(method, namespace, permission, call: token, then: proceed)
        })
    }

    /// The app's ledger for the notebook kernel `owner` runs: a kept
    /// "always" goes ahead, a kept "deny" is refused, and otherwise the
    /// person is asked through `ledgerPrompter` (refused without one).
    /// Nothing happens for a call cancelled meanwhile.
    private func checkLedger(
        _ method: String, _ namespace: String, call token: PendingCall, owner: Int,
        refused: @escaping @MainActor (String) -> Void, allowed: @escaping @MainActor () -> Void
    ) {
        guard let notebook = ledger.notebook(for: owner) else {
            refused("\(method): the app hasn't said which notebook this kernel runs")
            return
        }
        switch ledger.answer(notebook: notebook, capability: namespace) {
        case .always?:
            allowed()
        case .deny?:
            refused("\(method): \(notebook) isn't allowed \(namespace) (revoke it in Settings)")
        default:
            guard let prompter = ledgerPrompter else {
                refused("\(method): \(notebook) has no \(namespace) grant, and no one can be asked")
                return
            }
            ledgerRequests.ask(namespace, notebook: notebook, call: token.id, prompter: prompter, record: { [weak self] answer in
                // Under the notebook's path now, in case it moved while the prompt was up.
                guard let self else { return }
                self.ledger.record(answer, notebook: self.ledger.notebook(for: owner) ?? notebook, capability: namespace)
            }) { [weak self] answer in
                guard let self, self.pending.isWaiting(token) else { return }
                if answer == .once || answer == .always {
                    allowed()
                } else {
                    refused("\(method): \(notebook) wasn't allowed \(namespace)")
                }
            }
        }
    }

    /// The system (TCC) permission, asked when it hasn't been.
    private func askSystem(
        _ method: String, _ namespace: String, _ permission: Permission, call token: PendingCall,
        then proceed: @escaping @MainActor () -> Void
    ) {
        guard pending.isWaiting(token) else { return }
        let decide: @MainActor (PermissionStatus) -> Void = { [weak self] status in
            guard let self, self.pending.isWaiting(token) else { return }
            if status.isAuthorized {
                proceed()
            } else {
                self.pending.answer(token, Self.error("denied", "\(method): \(namespace) permission is \(status.rawValue)"))
            }
        }
        if permission.status == .notDetermined {
            requests.request(permission, decide)
        } else {
            decide(permission.status)
        }
    }

    /// Cancels the waiting calls of each owner that `matches`, and closes
    /// app prompts no other call waits on.
    private func cancelPending(_ matches: (Int) -> Bool) {
        for id in pending.cancel(owners: matches) {
            ledgerRequests.cancel(id, prompter: ledgerPrompter)
        }
    }

    private func run(_ handler: MethodHandler, _ params: [String: Any], call token: PendingCall) {
        guard pending.isWaiting(token) else { return }
        let cancel = handler(params) { [weak self] result in
            switch result {
            case let .success(value):
                self?.pending.answer(token, ["result": value])
            case let .failure(error):
                self?.pending.answer(token, Self.error(error.code, error.message))
            }
        }
        // Not when it already answered.
        if pending.isWaiting(token) { pending.setCancel(token, cancel) }
    }

    /// The hardware model identifier, such as "Mac14,2" or "iPad13,4".
    private static var model: String? {
        #if os(macOS)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        #else
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #endif
    }

    private static var platform: String {
        #if os(macOS)
        return "macos"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }

    static func error(_ code: String, _ message: String) -> [String: Any] {
        ["error": ["code": code, "message": message]]
    }

    // MARK: Binary values
    //
    // Nonisolated: `Dialog.init`, which calls these, isn't main-actor isolated.

    /// The largest binary value one call carries, either way: 16 MiB, as
    /// `MAX_BINARY_BYTES` in src/binary.ts.
    nonisolated public static let maxBinaryBytes = 16 * 1024 * 1024

    /// Why a binary value was refused. Its description is the reply's message.
    public struct BinaryError: Error, CustomStringConvertible {
        public let description: String
    }

    /// The bytes in a `{ base64 }` value (docs/protocol.md, "Binary values").
    nonisolated public static func bytes(_ value: Any?) throws -> Data {
        guard let object = value as? [String: Any], let text = object["base64"] as? String else {
            throw BinaryError(description: "expected bytes ({ base64 })")
        }
        // Every 4 characters are 3 bytes, less the padding; check before
        // decoding.
        let padding = text.hasSuffix("==") ? 2 : text.hasSuffix("=") ? 1 : 0
        guard text.utf8.count * 3 / 4 - padding <= maxBinaryBytes else {
            throw BinaryError(description: "binary values are limited to \(maxBinaryBytes) bytes")
        }
        guard let data = Data(base64Encoded: text) else {
            throw BinaryError(description: "malformed base64")
        }
        return data
    }

    /// `data` as a `{ base64 }` value.
    nonisolated public static func binary(_ data: Data) throws -> [String: Any] {
        guard data.count <= maxBinaryBytes else {
            throw BinaryError(description: "binary values are limited to \(maxBinaryBytes) bytes; this one is \(data.count)")
        }
        return ["base64": data.base64EncodedString()]
    }

    private static func binaryResult(_ data: Data) -> [String: Any] {
        do {
            return ["result": try binary(data)]
        } catch {
            return Self.error("failed", "\(error)")
        }
    }
}

/// The clipboard, behind a protocol so tests needn't touch the real one.
@MainActor
public protocol Clipboard {
    func readText() -> String?
    func writeText(_ text: String)
    /// The clipboard's image as PNG, or nil when it holds none.
    func readImage() -> Data?
    /// Puts an image on the clipboard. False when `data` isn't an image
    /// the platform reads (PNG, JPEG, GIF, HEIC, TIFF).
    func writeImage(_ data: Data) -> Bool
}

/// The system pasteboard.
@MainActor
public struct SystemClipboard: Clipboard {
    public init() {}

    public func readText() -> String? {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #else
        return UIPasteboard.general.string
        #endif
    }

    public func writeText(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    public func readImage() -> Data? {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        if let png = pasteboard.data(forType: .png) { return png }
        guard NSImage.canInit(with: pasteboard), let image = NSImage(pasteboard: pasteboard) else { return nil }
        return Self.png(image)
        #else
        let pasteboard = UIPasteboard.general
        // `hasImages` doesn't show the paste prompt; reading does.
        guard pasteboard.hasImages else { return nil }
        return pasteboard.data(forPasteboardType: UTType.png.identifier) ?? pasteboard.image?.pngData()
        #endif
    }

    public func writeImage(_ data: Data) -> Bool {
        #if os(macOS)
        guard let image = NSImage(data: data), let png = Self.png(image), let tiff = image.tiffRepresentation else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(tiff, forType: .tiff)
        return true
        #else
        guard let image = UIImage(data: data), let png = image.pngData() else { return false }
        UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
        return true
        #endif
    }

    #if os(macOS)
    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
    #endif
}

public enum ImpactStyle: String, Sendable {
    case light, medium, heavy, soft, rigid
}

public enum NotificationFeedback: String, Sendable {
    case success, warning, error
}

/// Taptic feedback, behind a protocol so tests needn't touch the hardware.
@MainActor
public protocol Haptics {
    /// Whether the device has a Taptic Engine. When false, `hello` leaves
    /// the haptics methods out and the bridge refuses them `unavailable`.
    var isAvailable: Bool { get }
    func impact(_ style: ImpactStyle)
    func notification(_ type: NotificationFeedback)
    func selection()
}

/// UIKit's feedback generators, on an iPhone. iPads and Macs have no
/// Taptic Engine (the generators do nothing there), so they report none.
@MainActor
public struct SystemHaptics: Haptics {
    public init() {}

    public var isAvailable: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    public func impact(_ style: ImpactStyle) {
        #if os(iOS)
        let styles: [ImpactStyle: UIImpactFeedbackGenerator.FeedbackStyle] = [
            .light: .light, .medium: .medium, .heavy: .heavy, .soft: .soft, .rigid: .rigid,
        ]
        UIImpactFeedbackGenerator(style: styles[style] ?? .medium).impactOccurred()
        #endif
    }

    public func notification(_ type: NotificationFeedback) {
        #if os(iOS)
        let types: [NotificationFeedback: UINotificationFeedbackGenerator.FeedbackType] = [
            .success: .success, .warning: .warning, .error: .error,
        ]
        UINotificationFeedbackGenerator().notificationOccurred(types[type] ?? .success)
        #endif
    }

    public func selection() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}

/// Opens URLs, behind a protocol so tests needn't open any.
@MainActor
public protocol URLOpener {
    /// `inApp` asks for a Safari view in the app instead of switching to
    /// Safari, where the platform has one.
    func open(_ url: URL, inApp: Bool)
}

/// `NSWorkspace` on the Mac; on iOS, `SFSafariViewController` over the
/// key window for an in-app web page, else the system's handler.
@MainActor
public struct SystemURLOpener: URLOpener {
    public init() {}

    public func open(_ url: URL, inApp: Bool) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        let web = url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
        if inApp, web, let top = Self.topViewController() {
            top.present(SFSafariViewController(url: url), animated: true)
        } else {
            UIApplication.shared.open(url)
        }
        #endif
    }

    #if os(iOS)
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = (scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first)?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
    #endif
}

/// What `info` adds to `hello`: state that can change while a kernel
/// runs, read when a cell asks. Behind a protocol so tests can fix it.
@MainActor
public protocol DeviceState {
    /// `isPad`, `screen { width, height, scale }`, `battery { level,
    /// charging }` (left out without a battery), `darkMode` and `locale`.
    func current() -> [String: Any]
}

@MainActor
public struct SystemDeviceState: DeviceState {
    public init() {}

    public func current() -> [String: Any] {
        var state: [String: Any] = [
            "locale": Locale.current.identifier(.bcp47),
        ]
        #if os(macOS)
        state["isPad"] = false
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        state["darkMode"] = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let screen = NSScreen.main {
            state["screen"] = [
                "width": Double(screen.frame.width),
                "height": Double(screen.frame.height),
                "scale": Double(screen.backingScaleFactor),
            ]
        }
        state["battery"] = Self.battery()
        #else
        let device = UIDevice.current
        state["isPad"] = device.userInterfaceIdiom == .pad
        state["darkMode"] = UITraitCollection.current.userInterfaceStyle == .dark
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let screen = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen {
            state["screen"] = [
                "width": Double(screen.bounds.width),
                "height": Double(screen.bounds.height),
                "scale": Double(screen.scale),
            ]
        }
        device.isBatteryMonitoringEnabled = true
        if device.batteryState != .unknown {
            state["battery"] = [
                "level": device.batteryLevel >= 0 ? Double(device.batteryLevel) as Any : NSNull(),
                "charging": device.batteryState == .charging || device.batteryState == .full,
            ] as [String: Any]
        }
        #endif
        return state
    }

    #if os(macOS)
    /// The internal battery, or nil on a Mac without one.
    private static func battery() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as NSArray?
        else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source as CFTypeRef)?
                .takeUnretainedValue() as NSDictionary? as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            var level: Any = NSNull()
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                level = Double(current) / Double(max)
            }
            return ["level": level, "charging": description[kIOPSIsChargingKey] as? Bool ?? false]
        }
        return nil
    }
    #endif
}
