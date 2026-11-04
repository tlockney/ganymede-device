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
    private let appVersion: String

    public init(
        clipboard: Clipboard? = nil,
        haptics: Haptics? = nil,
        urlOpener: URLOpener? = nil,
        state: DeviceState? = nil,
        presenter: DialogPresenter? = nil,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    ) {
        // Made here, not as the default arguments: defaults are evaluated
        // outside the main actor.
        self.clipboard = clipboard ?? SystemClipboard()
        self.haptics = haptics ?? SystemHaptics()
        self.urlOpener = urlOpener ?? SystemURLOpener()
        self.state = state ?? SystemDeviceState()
        self.dialogs = DialogQueue(presenter: presenter ?? SystemDialogPresenter())
        self.appVersion = appVersion
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

    /// Closes every dialog shown or waiting, as when the kernel page
    /// navigates or its web content process ends (docs/protocol.md): the
    /// new page's ids start over, so none of them may be answered. Call it
    /// from the web view's navigation delegate.
    public func dropAll() {
        dialogs.dropAll()
    }

    /// One message's reply: `{ result }` or `{ error: { code, message } }`.
    /// Dialogs (`ui.*`) answer later, so they go through
    /// `respond(to:reply:)`; here they fail `failed`.
    public func handle(_ body: Any) -> [String: Any] {
        guard let call = body as? [String: Any] else {
            return Self.error("failed", "a device message must be an object")
        }
        if call["cancel"] as? Bool == true {
            // Closes the dialog the call showed, or takes it off the queue.
            if let id = Self.callID(call["id"]) {
                dialogs.cancel(id)
            }
            return ["result": NSNull()]
        }
        guard let method = call["method"] as? String else {
            return Self.error("failed", "a device call needs a method")
        }
        let params = call["params"] as? [String: Any] ?? [:]
        switch method {
        case "hello":
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
        case _ where Self.dialogMethods.contains(method):
            return Self.error("failed", "\(method) answers later; send it through respond(to:reply:)")
        default:
            return Self.error("unavailable", "\(method) isn't available in this app")
        }
    }

    /// A call's `id`: the page sends a number, which WebKit hands over as
    /// an NSNumber.
    private static func callID(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(exactly: n) }
        return nil
    }

    /// The methods every bridge answers. `capabilities` adds what this
    /// device has.
    public static let capabilities = [
        "clipboard.readText", "clipboard.writeText", "clipboard.readImage", "clipboard.writeImage", "info", "openURL",
        "ui.alert", "ui.confirm", "ui.prompt", "ui.actionSheet", "ui.pickDate",
    ]

    /// The methods that show a dialog and answer once it closes.
    public static let dialogMethods: Set<String> = ["ui.alert", "ui.confirm", "ui.prompt", "ui.actionSheet", "ui.pickDate"]

    /// The methods this bridge answers, as `hello` reports them.
    public var capabilities: [String] {
        Self.capabilities + (haptics.isAvailable ? ["haptics.impact", "haptics.notification", "haptics.selection"] : [])
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

    /// The largest binary value one call carries, either way: 16 MiB, as
    /// `MAX_BINARY_BYTES` in src/binary.ts.
    public static let maxBinaryBytes = 16 * 1024 * 1024

    /// Why a binary value was refused. Its description is the reply's message.
    public struct BinaryError: Error, CustomStringConvertible {
        public let description: String
    }

    /// The bytes in a `{ base64 }` value (docs/protocol.md, "Binary values").
    public static func bytes(_ value: Any?) throws -> Data {
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
    public static func binary(_ data: Data) throws -> [String: Any] {
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
