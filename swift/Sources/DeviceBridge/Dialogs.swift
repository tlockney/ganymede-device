import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// `device.ui.*`: dialogs a cell shows over the notebook and waits on
// (docs/protocol.md, "Dialogs"). The bridge parses each call into a
// `Dialog`, a `DialogQueue` shows one at a time through a
// `DialogPresenter`, and the person's answer becomes the reply.

public enum DateMode: String, Sendable {
    case date, time, datetime
}

/// One dialog, as a cell asked for it.
public enum Dialog: Equatable, Sendable {
    case alert(title: String?, message: String)
    case confirm(title: String?, message: String, destructive: Bool, okLabel: String?)
    case prompt(title: String?, message: String, placeholder: String?, defaultValue: String?, secure: Bool)
    case actionSheet(title: String, message: String?, options: [String], cancel: String?, destructive: Int?)
    case pickDate(title: String?, mode: DateMode, value: Date?, min: Date?, max: Date?)

    /// Why a dialog call's params were refused. Its description is the
    /// reply's message.
    public struct ParamsError: Error, CustomStringConvertible {
        public let description: String
    }

    /// The dialog a `ui.*` call asks for.
    public init(method: String, params: [String: Any]) throws {
        func text(_ key: String) -> String? { params[key] as? String }
        func need(_ key: String) throws -> String {
            guard let value = text(key) else { throw ParamsError(description: "\(method) needs a \(key) string") }
            return value
        }
        func date(_ key: String) throws -> Date? {
            guard let value = params[key], !(value is NSNull) else { return nil }
            guard let text = value as? String, let date = Self.parseDate(text) else {
                throw ParamsError(description: "\(method): \(key) must be an ISO 8601 date")
            }
            return date
        }
        switch method {
        case "ui.alert":
            self = .alert(title: text("title"), message: try need("message"))
        case "ui.confirm":
            self = .confirm(
                title: text("title"), message: try need("message"),
                destructive: params["destructive"] as? Bool ?? false, okLabel: text("okLabel")
            )
        case "ui.prompt":
            self = .prompt(
                title: text("title"), message: try need("message"), placeholder: text("placeholder"),
                defaultValue: text("defaultValue"), secure: params["secure"] as? Bool ?? false
            )
        case "ui.actionSheet":
            guard let options = params["options"] as? [String], !options.isEmpty else {
                throw ParamsError(description: "ui.actionSheet needs a non-empty options array of strings")
            }
            self = .actionSheet(
                title: try need("title"), message: text("message"), options: options,
                cancel: text("cancel"), destructive: (params["destructive"] as? NSNumber)?.intValue
            )
        case "ui.pickDate":
            guard let mode = DateMode(rawValue: text("mode") ?? "datetime") else {
                throw ParamsError(description: "ui.pickDate takes a mode of date, time or datetime")
            }
            self = .pickDate(title: text("title"), mode: mode, value: try date("value"), min: try date("min"), max: try date("max"))
        default:
            throw ParamsError(description: "\(method) isn't a dialog")
        }
    }

    /// The reply's `result` for the person's answer: `null` for an alert
    /// and for any dismissal, `false` for a dismissed confirm.
    public func result(_ answer: DialogResult) -> Any {
        switch (self, answer) {
        case (.confirm, .confirmed):
            return true
        case (.confirm, _):
            return false
        case let (.prompt, .text(text)):
            return text
        case let (.actionSheet(_, _, options, _, _), .option(index)) where options.indices.contains(index):
            return index
        case let (.pickDate, .date(date)):
            return Self.formatDate(date)
        default:
            return NSNull()
        }
    }

    /// Reads what `Date.prototype.toISOString` writes, with or without
    /// fractional seconds.
    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// What the person did with a dialog.
public enum DialogResult: Equatable, Sendable {
    /// Cancel, Escape, or a swipe down: not an error.
    case dismissed
    /// An alert's OK.
    case ok
    /// A confirm's confirming button.
    case confirmed
    case text(String)
    case option(Int)
    case date(Date)
}

/// Shows dialogs, behind a protocol so tests needn't show any.
@MainActor
public protocol DialogPresenter {
    /// Shows `dialog` and calls `done` once with the person's answer. The
    /// closure it returns closes the dialog without an answer; `done` may
    /// still be called then, and is ignored. Throws when there is nowhere
    /// to show it, such as no window.
    func present(_ dialog: Dialog, done: @escaping (DialogResult) -> Void) throws -> () -> Void
}

/// One dialog at a time: a second call waits for the first to close, in
/// the order the calls came. A cancel closes the one it names, or takes
/// it off the queue.
@MainActor
final class DialogQueue {
    enum Outcome {
        case answered(Any)
        case cancelled
        case failed(String, String)
    }

    private struct Waiting {
        let id: Int
        let dialog: Dialog
        let reply: (Outcome) -> Void
    }

    /// The dialog showing; compared by identity, so a late answer for one
    /// already closed is dropped.
    private final class Showing {
        let id: Int
        let reply: (Outcome) -> Void
        var close: (() -> Void)?
        init(id: Int, reply: @escaping (Outcome) -> Void) {
            self.id = id
            self.reply = reply
        }
    }

    private let presenter: DialogPresenter
    private var waiting: [Waiting] = []
    private var showing: Showing?

    init(presenter: DialogPresenter) {
        self.presenter = presenter
    }

    func show(_ dialog: Dialog, id: Int, reply: @escaping (Outcome) -> Void) {
        waiting.append(Waiting(id: id, dialog: dialog, reply: reply))
        next()
    }

    func cancel(_ id: Int) {
        if let current = showing, current.id == id {
            showing = nil
            current.close?()
            current.reply(.cancelled)
            next()
        } else if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).reply(.cancelled)
        }
    }

    func dropAll() {
        let dropped = waiting
        waiting = []
        if let current = showing {
            showing = nil
            current.close?()
            current.reply(.cancelled)
        }
        for call in dropped {
            call.reply(.cancelled)
        }
    }

    private func next() {
        guard showing == nil, !waiting.isEmpty else { return }
        let call = waiting.removeFirst()
        let current = Showing(id: call.id, reply: call.reply)
        showing = current
        do {
            let close = try presenter.present(call.dialog) { [weak self] answer in
                self?.finish(current, .answered(call.dialog.result(answer)))
            }
            current.close = close
        } catch {
            finish(current, .failed("unavailable", "\(error)"))
        }
    }

    private func finish(_ current: Showing, _ outcome: Outcome) {
        guard showing === current else { return }
        showing = nil
        current.reply(outcome)
        next()
    }
}

/// Why the system presenter couldn't show a dialog.
public struct DialogUnavailable: Error, CustomStringConvertible {
    public let description: String
}

#if os(macOS)

/// `NSAlert` sheets on the app's key window.
@MainActor
public struct SystemDialogPresenter: DialogPresenter {
    public init() {}

    public func present(_ dialog: Dialog, done: @escaping (DialogResult) -> Void) throws -> () -> Void {
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow ?? NSApp?.windows.first(where: { $0.isVisible }) else {
            throw DialogUnavailable(description: "there is no window to show a dialog on")
        }
        let alert = NSAlert()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let answer: (NSApplication.ModalResponse) -> DialogResult
        switch dialog {
        case let .alert(title, message):
            Self.text(alert, title: title, message: message)
            alert.addButton(withTitle: "OK")
            answer = { _ in .ok }
        case let .confirm(title, message, destructive, okLabel):
            Self.text(alert, title: title, message: message)
            alert.addButton(withTitle: okLabel ?? "OK").hasDestructiveAction = destructive
            alert.addButton(withTitle: "Cancel")
            answer = { $0.rawValue == first ? .confirmed : .dismissed }
        case let .prompt(title, message, placeholder, defaultValue, secure):
            Self.text(alert, title: title, message: message)
            let field = secure ? NSSecureTextField() : NSTextField()
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            field.placeholderString = placeholder
            field.stringValue = defaultValue ?? ""
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            answer = { $0.rawValue == first ? .text(field.stringValue) : .dismissed }
        case let .actionSheet(title, message, options, cancel, destructive):
            alert.messageText = title
            alert.informativeText = message ?? ""
            for (index, option) in options.enumerated() {
                alert.addButton(withTitle: option).hasDestructiveAction = index == destructive
            }
            alert.addButton(withTitle: cancel ?? "Cancel")
            answer = { response in
                let index = response.rawValue - first
                return options.indices.contains(index) ? .option(index) : .dismissed
            }
        case let .pickDate(title, mode, value, min, max):
            alert.messageText = title ?? (mode == .time ? "Choose a time" : "Choose a date")
            let picker = NSDatePicker()
            picker.datePickerStyle = mode == .time ? .textFieldAndStepper : .clockAndCalendar
            switch mode {
            case .date: picker.datePickerElements = .yearMonthDay
            case .time: picker.datePickerElements = .hourMinute
            case .datetime: picker.datePickerElements = [.yearMonthDay, .hourMinute]
            }
            picker.minDate = min
            picker.maxDate = max
            picker.dateValue = value ?? Date()
            picker.sizeToFit()
            alert.accessoryView = picker
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            answer = { $0.rawValue == first ? .date(picker.dateValue) : .dismissed }
        }
        alert.beginSheetModal(for: window) { response in
            done(answer(response))
        }
        return { [weak window] in
            window?.endSheet(alert.window, returnCode: .cancel)
        }
    }

    /// A title in bold with the message under it, or the message alone.
    private static func text(_ alert: NSAlert, title: String?, message: String) {
        if let title {
            alert.messageText = title
            alert.informativeText = message
        } else {
            alert.messageText = message
        }
    }
}

#else

/// `UIAlertController`s, and a date picker sheet, over the key window's
/// top view controller.
@MainActor
public struct SystemDialogPresenter: DialogPresenter {
    public init() {}

    public func present(_ dialog: Dialog, done: @escaping (DialogResult) -> Void) throws -> () -> Void {
        guard let top = Self.topViewController() else {
            throw DialogUnavailable(description: "there is no window to show a dialog on")
        }
        let controller: UIViewController
        switch dialog {
        case let .alert(title, message):
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done(.ok) })
            controller = alert
        case let .confirm(title, message, destructive, okLabel):
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(.dismissed) })
            alert.addAction(UIAlertAction(title: okLabel ?? "OK", style: destructive ? .destructive : .default) { _ in
                done(.confirmed)
            })
            controller = alert
        case let .prompt(title, message, placeholder, defaultValue, secure):
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addTextField { field in
                field.placeholder = placeholder
                field.text = defaultValue
                field.isSecureTextEntry = secure
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(.dismissed) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                done(.text(alert?.textFields?.first?.text ?? ""))
            })
            controller = alert
        case let .actionSheet(title, message, options, cancel, destructive):
            let sheet = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
            for (index, option) in options.enumerated() {
                sheet.addAction(UIAlertAction(title: option, style: index == destructive ? .destructive : .default) { _ in
                    done(.option(index))
                })
            }
            sheet.addAction(UIAlertAction(title: cancel ?? "Cancel", style: .cancel) { _ in done(.dismissed) })
            // An iPad shows an action sheet as a popover, which needs an
            // anchor: the middle of the view, with no arrow.
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = top.view
                popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            controller = sheet
        case let .pickDate(title, mode, value, min, max):
            let picker = DatePickerController(title: title, mode: mode, value: value, min: min, max: max, done: done)
            let navigation = UINavigationController(rootViewController: picker)
            navigation.modalPresentationStyle = .formSheet
            navigation.presentationController?.delegate = picker
            controller = navigation
        }
        top.present(controller, animated: true)
        return { [weak controller] in
            controller?.dismiss(animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = (scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first)?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

/// A date or time picker with Cancel and Done, as a sheet.
@MainActor
final class DatePickerController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let picker = UIDatePicker()
    private let done: (DialogResult) -> Void
    private var answered = false

    init(title: String?, mode: DateMode, value: Date?, min: Date?, max: Date?, done: @escaping (DialogResult) -> Void) {
        self.done = done
        super.init(nibName: nil, bundle: nil)
        self.title = title
        switch mode {
        case .date: picker.datePickerMode = .date
        case .time: picker.datePickerMode = .time
        case .datetime: picker.datePickerMode = .dateAndTime
        }
        picker.preferredDatePickerStyle = mode == .time ? .wheels : .inline
        picker.minimumDate = min
        picker.maximumDate = max
        picker.date = value ?? Date()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not from a storyboard")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        picker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            picker.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.finish(.dismissed)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.finish(.date(self.picker.date))
        })
    }

    private func finish(_ answer: DialogResult) {
        guard !answered else { return }
        answered = true
        dismiss(animated: true)
        done(answer)
    }

    /// A swipe down is a dismissal.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard !answered else { return }
        answered = true
        done(.dismissed)
    }
}

#endif
