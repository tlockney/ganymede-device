import Foundation
#if os(macOS)
import AppKit
import Quartz
#else
import QuickLook
import UIKit
#endif

// `device.share` and `device.preview`: the system share sheet and Quick
// Look, shown through the dialog queue (Dialogs.swift) so they take turns
// with dialogs and close on a cancel the same way. The files a cell hands
// over are written to a temporary folder first, since both take file URLs.

extension NamedFile {
    /// A name a file can be written under as it is: not empty, `.` or `..`,
    /// and no slash, backslash or NUL.
    public static func isPlainName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && name != "." && name != ".."
            && !name.contains(where: { $0 == "/" || $0 == "\\" || $0 == "\0" })
    }
}

/// A cell's files written to a fresh temporary folder, each in a folder of
/// its own so two files can share a name.
final class TemporaryFiles {
    let directory: URL
    let urls: [URL]

    init(_ files: [NamedFile]) throws {
        let fm = FileManager.default
        directory = fm.temporaryDirectory
            .appendingPathComponent("ganymede-device", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var urls: [URL] = []
        do {
            for (index, file) in files.enumerated() {
                let folder = directory.appendingPathComponent(String(index), isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(file.name, isDirectory: false)
                try file.data.write(to: url)
                urls.append(url)
            }
        } catch {
            try? fm.removeItem(at: directory)
            throw DialogUnavailable(description: "couldn't write the files to show: \(error.localizedDescription)")
        }
        self.urls = urls
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes the files once the app they were sent to has had time to
    /// read them; a share can hand over a URL and read it after the sheet
    /// has gone.
    func removeLater(after seconds: TimeInterval = 600) {
        let directory = self.directory
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private func shareItems(text: String?, url: URL?, files: TemporaryFiles) -> [Any] {
    var items: [Any] = []
    if let text { items.append(text) }
    if let url { items.append(url) }
    items.append(contentsOf: files.urls)
    return items
}

#if os(macOS)

/// `NSSharingServicePicker`, the Mac's share menu, over the middle of the
/// asking page's view.
@MainActor
enum SharePresenter {
    static func present(
        text: String?, url: URL?, files: [NamedFile], on host: DialogHost?, window: NSWindow,
        done: @escaping (DialogResult) -> Void
    ) throws -> Close {
        guard let view = host ?? window.contentView else {
            throw DialogUnavailable(description: "there is no view to show the share menu on")
        }
        let temp = try TemporaryFiles(files)
        let picker = NSSharingServicePicker(items: shareItems(text: text, url: url, files: temp))
        let delegate = ShareDelegate(temp: temp, done: done)
        picker.delegate = delegate
        ShareDelegate.live.insert(delegate)
        // The menu tracks the mouse modally; show it after this call returns.
        Task { @MainActor [weak view] in
            guard let view, !delegate.closed else { return delegate.finish(nil) }
            let rect = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
        // A menu can't be closed from here; a cancel answers now, and the
        // menu's own close is ignored.
        return { gone in
            delegate.closed = true
            gone()
        }
    }
}

@MainActor
private final class ShareDelegate: NSObject, NSSharingServicePickerDelegate {
    /// Kept alive until the menu closes: the picker holds its delegate weakly.
    static var live: Set<ShareDelegate> = []
    let temp: TemporaryFiles
    let done: (DialogResult) -> Void
    var closed = false
    private var finished = false

    init(temp: TemporaryFiles, done: @escaping (DialogResult) -> Void) {
        self.temp = temp
        self.done = done
    }

    func finish(_ service: NSSharingService?) {
        guard !finished else { return }
        finished = true
        Self.live.remove(self)
        temp.removeLater()
        done(service == nil ? .dismissed : .shared)
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        finish(service)
    }
}

/// Quick Look in a sheet on the asking notebook's window: a `QLPreviewView`
/// with Previous and Next for several files, and Done.
@MainActor
enum PreviewPresenter {
    static func present(files: [NamedFile], window: NSWindow, done: @escaping (DialogResult) -> Void) throws -> Close {
        let temp = try TemporaryFiles(files)
        let sheet = PreviewSheet(urls: temp.urls)
        window.beginSheet(sheet.window) { _ in
            temp.remove()
            done(.dismissed)
            _ = sheet // held until the sheet ends
        }
        return { [weak window] gone in
            window?.endSheet(sheet.window)
            gone()
        }
    }
}

@MainActor
private final class PreviewSheet: NSObject {
    let window: NSWindow
    private let urls: [URL]
    private var index = 0
    private let preview: QLPreviewView
    private let name = NSTextField(labelWithString: "")
    private let previous = NSButton(title: "Previous", target: nil, action: nil)
    private let next = NSButton(title: "Next", target: nil, action: nil)

    init(urls: [URL]) {
        self.urls = urls
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 760, height: 500), style: .normal)!
        super.init()
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.keyEquivalent = "\r"
        previous.target = self
        previous.action = #selector(showPrevious)
        next.target = self
        next.action = #selector(showNext)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: urls.count > 1 ? [name, previous, next, done] : [name, done])
        buttons.orientation = .horizontal
        buttons.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        let stack = NSStackView(views: [preview, buttons])
        stack.orientation = .vertical
        stack.spacing = 0
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack
        show(0)
    }

    private func show(_ i: Int) {
        index = i
        preview.previewItem = urls[i] as NSURL
        name.stringValue = urls.count > 1 ? "\(urls[i].lastPathComponent) (\(i + 1) of \(urls.count))" : urls[i].lastPathComponent
        previous.isEnabled = i > 0
        next.isEnabled = i < urls.count - 1
    }

    @objc private func showPrevious() { if index > 0 { show(index - 1) } }
    @objc private func showNext() { if index < urls.count - 1 { show(index + 1) } }

    @objc private func close() {
        window.sheetParent?.endSheet(window)
    }

    /// Escape closes it, as it would a sheet with a Cancel button.
    @objc func cancelOperation(_ sender: Any?) {
        close()
    }
}

#else

/// `UIActivityViewController`, anchored in the middle of the page with no
/// arrow when an iPad shows it as a popover.
@MainActor
enum SharePresenter {
    static func controller(
        text: String?, url: URL?, files: [NamedFile], anchor: UIView, done: @escaping (DialogResult) -> Void
    ) throws -> UIViewController {
        let temp = try TemporaryFiles(files)
        let sheet = UIActivityViewController(activityItems: shareItems(text: text, url: url, files: temp), applicationActivities: nil)
        var answered = false
        // Called once the sheet, and any activity it showed, has gone.
        sheet.completionWithItemsHandler = { _, completed, _, _ in
            guard !answered else { return }
            answered = true
            temp.removeLater()
            done(completed ? .shared : .dismissed)
        }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = CGRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return sheet
    }
}

/// `QLPreviewController` over the files, answering once it has gone.
@MainActor
enum PreviewPresenter {
    static func controller(files: [NamedFile], done: @escaping (DialogResult) -> Void) throws -> UIViewController {
        PreviewController(temp: try TemporaryFiles(files), done: done)
    }
}

@MainActor
private final class PreviewController: QLPreviewController, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    private let temp: TemporaryFiles
    private let done: (DialogResult) -> Void
    private var answered = false

    init(temp: TemporaryFiles, done: @escaping (DialogResult) -> Void) {
        self.temp = temp
        self.done = done
        super.init(nibName: nil, bundle: nil)
        dataSource = self
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not from a storyboard")
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        temp.urls.count
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        temp.urls[index] as NSURL
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        guard !answered else { return }
        answered = true
        temp.remove()
        done(.dismissed)
    }
}

#endif
