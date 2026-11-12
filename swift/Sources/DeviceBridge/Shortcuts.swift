import Foundation

// `device.shortcuts.run` (#40): runs a Shortcut through the Shortcuts
// app's x-callback URL and answers with its output. The Shortcuts app
// comes forward while it runs and opens one of `callback`'s URLs when it
// is done; the app hands those to `ShortcutCalls.handle(_:)`.

/// The Shortcuts the bridge started and is waiting on, keyed by a token
/// in the callback URLs. Share one between the app's bridges, and give
/// it every URL the app is opened with: `handle` answers the ones that
/// are its own.
@MainActor
public final class ShortcutCalls {
    /// Where the Shortcuts app calls back, such as
    /// `ganymede://device-callback/shortcuts`: a URL whose scheme the app handles.
    public let callback: URL
    private var waiting: [String: MethodReply] = [:]

    public init(callback: URL) {
        self.callback = callback
    }

    /// The `shortcuts://` URL that runs `name` with `input` and calls back
    /// to `<callback>/<token>/success|error|cancel`.
    func runURL(name: String, input: String?, token: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "shortcuts"
        parts.host = "x-callback-url"
        parts.path = "/run-shortcut"
        var query = [URLQueryItem(name: "name", value: name)]
        if let input {
            query += [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: input)]
        }
        for outcome in ["success", "error", "cancel"] {
            query.append(URLQueryItem(name: "x-\(outcome)", value: callback.appendingPathComponent(token).appendingPathComponent(outcome).absoluteString))
        }
        parts.queryItems = query
        // `+` is a space to some query parsers: spell it out.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    /// Waits for the callback with `token`; the returned action stops
    /// waiting (an interrupt), after which a late callback is ignored.
    func wait(_ token: String, reply: @escaping MethodReply) -> () -> Void {
        waiting[token] = reply
        return { [weak self] in self?.waiting[token] = nil }
    }

    /// Answers the call a Shortcuts callback is for. True when `url` is
    /// one of this object's callbacks, waited on or not, so the app
    /// doesn't treat it as anything else.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == callback.scheme?.lowercased(),
              url.host?.lowercased() == callback.host?.lowercased()
        else { return false }
        let base = callback.pathComponents.filter { $0 != "/" }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count == base.count + 2, Array(path.prefix(base.count)) == base else { return false }
        let token = path[base.count]
        let outcome = path[base.count + 1]
        guard ["success", "error", "cancel"].contains(outcome) else { return true }
        guard let reply = waiting.removeValue(forKey: token) else { return true }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        switch outcome {
        case "success":
            reply(.success(value("result").map { $0 as Any } ?? NSNull()))
        case "cancel":
            reply(.failure(DeviceCallError("cancelled", "shortcuts.run: the Shortcut was cancelled")))
        default: // "error"
            let message = value("errorMessage").flatMap { $0.isEmpty ? nil : $0 } ?? "the Shortcut failed"
            reply(.failure(DeviceCallError("failed", "shortcuts.run: \(message)")))
        }
        return true
    }

    /// Rejects the call waiting on `token`, if it still is, when the
    /// Shortcuts URL couldn't be opened.
    func openFailed(_ token: String) {
        waiting.removeValue(forKey: token)?(.failure(DeviceCallError("unavailable", "shortcuts.run: the Shortcuts app couldn't be opened")))
    }

    /// How many calls are waiting, for tests.
    var waitingCount: Int { waiting.count }
}

extension DeviceBridge {
    /// The longest Shortcut name, and input, the bridge sends.
    static let maxShortcutName = 256
    static let maxShortcutInput = 64 * 1024

    /// Turns on `device.shortcuts.run`, under capability `shortcuts`, which
    /// has no system permission: the ledger's prompt is the only consent,
    /// since a Shortcut can do anything the person set it up to. `calls`
    /// waits for the Shortcuts app's callbacks; the app passes it every
    /// URL it is opened with.
    public func addShortcuts(_ calls: ShortcutCalls) {
        addPermission("shortcuts", LedgerOnlyPermission())
        foregroundMethods.insert("shortcuts.run")
        addMethod("shortcuts.run", permission: "shortcuts", check: { _ = try Self.shortcutRequest($0) }, handler: { [weak self] params, reply in
            do {
                let (name, input) = try Self.shortcutRequest(params)
                let token = UUID().uuidString
                let stop = calls.wait(token, reply: reply)
                // A Shortcuts app that's gone (iOS lets you delete it)
                // never calls back: fail now rather than wait.
                self?.urlOpener.open(calls.runURL(name: name, input: input, token: token)) { opened in
                    if !opened { calls.openFailed(token) }
                }
                return stop
            } catch {
                reply(.failure(error as? DeviceCallError ?? DeviceCallError("failed", "shortcuts.run: \(error)")))
                return nil
            }
        })
    }

    static func shortcutRequest(_ params: [String: Any]) throws -> (name: String, input: String?) {
        guard let name = params["name"] as? String, !name.isEmpty, name.utf8.count <= maxShortcutName else {
            throw DeviceCallError("failed", "shortcuts.run: name must be a Shortcut's name, 1 to \(maxShortcutName) bytes")
        }
        let input = params["input"]
        if input == nil || input is NSNull { return (name, nil) }
        guard let text = input as? String, text.utf8.count <= maxShortcutInput else {
            throw DeviceCallError("failed", "shortcuts.run: input must be text, up to \(maxShortcutInput) bytes")
        }
        return (name, text)
    }
}
