import Foundation
import ObjectiveC
import PhotosUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// `device.files.pick`, `device.files.export` and `device.photos.pick`: the
// system's own pickers, shown through the dialog queue (Dialogs.swift).
// A picker is the person's consent, so there is no permission prompt, and
// a picked file is read in by value: no bookmark or other access is kept.

/// Reads picked files, refusing when they are together over the binary
/// limit.
enum PickedFiles {
    static func read(_ urls: [URL], removeAfter: Bool = false) -> DialogResult {
        var files: [PickedFile] = []
        var total = 0
        defer {
            if removeAfter {
                for url in urls { try? FileManager.default.removeItem(at: url) }
            }
        }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // The size first, so a large file isn't read just to be refused.
                total += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard total <= DeviceBridge.maxBinaryBytes else { return tooLarge }
                let data = try Data(contentsOf: url)
                files.append(PickedFile(name: url.lastPathComponent, type: mimeType(url.pathExtension), data: data))
            } catch {
                return .failed("couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard files.reduce(0, { $0 + $1.data.count }) <= DeviceBridge.maxBinaryBytes else { return tooLarge }
        return .files(files)
    }

    /// `read` off the main thread (a file on a network volume or in iCloud
    /// can take a while), answering on the main queue.
    static func readInBackground(_ urls: [URL], removeAfter: Bool = false, done: @escaping (DialogResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = read(urls, removeAfter: removeAfter)
            DispatchQueue.main.async { done(result) }
        }
    }

    static let tooLargeMessage = "the picked files together are over \(DeviceBridge.maxBinaryBytes) bytes"
    static let tooLarge = DialogResult.failed(tooLargeMessage)

    static func mimeType(_ pathExtension: String) -> String {
        UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? ""
    }
}

/// Loads what a photo picker handed over, each in the format it is stored
/// in, and answers on the main queue.
enum PhotoLoader {
    private final class Gathered: @unchecked Sendable {
        let lock = NSLock()
        var files: [PickedFile?]
        var failure: String?
        var total = 0
        init(count: Int) { files = Array(repeating: nil, count: count) }
    }

    /// Stops reading once the photos together pass `limit`, so a large
    /// selection fails rather than filling memory.
    static func load(_ providers: [NSItemProvider], limit: Int = DeviceBridge.maxBinaryBytes, done: @escaping (DialogResult) -> Void) {
        guard !providers.isEmpty else { return done(.dismissed) }
        let gathered = Gathered(count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            let type = provider.registeredTypeIdentifiers.lazy.compactMap { UTType($0) }.first { $0.conforms(to: .image) }
            guard let type else {
                gathered.lock.lock()
                gathered.failure = "a picked item isn't an image"
                gathered.lock.unlock()
                continue
            }
            // After a non-image item, ask for no more copies. (The size
            // limit is checked as each copy arrives; the copies are
            // asked for together, so this rarely sees that failure.)
            gathered.lock.lock()
            let failed = gathered.failure != nil
            gathered.lock.unlock()
            if failed { break }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                defer { group.leave() }
                // The file is removed once this returns, so read it now.
                let result: Result<PickedFile, Error> = Result {
                    guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    // Count it before reading, and skip the read once over.
                    gathered.lock.lock()
                    let over = gathered.failure != nil || gathered.total + size > limit
                    if !over { gathered.total += size }
                    gathered.lock.unlock()
                    guard !over else { throw TooLarge() }
                    let name = (provider.suggestedName ?? "photo-\(index + 1)") + "." + (type.preferredFilenameExtension ?? url.pathExtension)
                    return PickedFile(name: name, type: type.preferredMIMEType ?? "", data: try Data(contentsOf: url))
                }
                gathered.lock.lock()
                defer { gathered.lock.unlock() }
                switch result {
                case let .success(file): gathered.files[index] = file
                case .failure(is TooLarge): gathered.failure = gathered.failure ?? PickedFiles.tooLargeMessage
                case let .failure(error): gathered.failure = "couldn't load a picked photo: \(error.localizedDescription)"
                }
            }
        }
        group.notify(queue: .main) {
            if let failure = gathered.failure { return done(.failed(failure)) }
            let files = gathered.files.compactMap { $0 }
            guard files.reduce(0, { $0 + $1.data.count }) <= limit else { return done(PickedFiles.tooLarge) }
            done(.files(files))
        }
    }

    private struct TooLarge: Error {}
}

private var retainedKey: UInt8 = 0

/// Keeps `object` alive as long as `owner`: pickers hold their delegates
/// weakly.
func retain(_ object: AnyObject, by owner: AnyObject) {
    objc_setAssociatedObject(owner, &retainedKey, object, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

/// The system photo picker, which shows the library without the app being
/// let in: images only, `limit` 0 for no limit.
@MainActor
private func photoPicker(limit: Int, finished: @escaping (PHPickerViewController, [PHPickerResult]) -> Void) -> PHPickerViewController {
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = limit
    let picker = PHPickerViewController(configuration: configuration)
    let delegate = PhotoPickerDelegate(finished: finished)
    picker.delegate = delegate
    retain(delegate, by: picker)
    return picker
}

private final class PhotoPickerDelegate: NSObject, PHPickerViewControllerDelegate {
    let finished: (PHPickerViewController, [PHPickerResult]) -> Void
    private var answered = false

    init(finished: @escaping (PHPickerViewController, [PHPickerResult]) -> Void) {
        self.finished = finished
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard !answered else { return }
        answered = true
        finished(picker, results)
    }
}

#if os(macOS)

/// The open and save panels, as sheets on the asking notebook's window.
@MainActor
enum FilePanels {
    static func open(types: [String], multiple: Bool, window: NSWindow, done: @escaping (DialogResult) -> Void) -> Close {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        let contentTypes = types.compactMap { UTType($0) }
        if !contentTypes.isEmpty { panel.allowedContentTypes = contentTypes }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return done(.dismissed) }
            PickedFiles.readInBackground(panel.urls, done: done)
        }
        return { [weak window] gone in
            window?.endSheet(panel)
            gone()
        }
    }

    /// `folders.pick`: one folder, which the person may make here. The
    /// panel says what the notebook may do with it, since picking is the
    /// consent: read only, or change and delete too.
    static func folder(write: Bool, window: NSWindow, done: @escaping (DialogResult) -> Void) -> Close {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = write
            ? "The notebook will be able to read, change and delete files in the folder you choose."
            : "The notebook will be able to read the files in the folder you choose."
        panel.prompt = write ? "Allow Changes" : "Allow Reading"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return done(.dismissed) }
            done(.folder(url))
        }
        return { [weak window] gone in
            window?.endSheet(panel)
            gone()
        }
    }

    static func save(_ file: NamedFile, window: NSWindow, done: @escaping (DialogResult) -> Void) -> Close {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return done(.dismissed) }
            do {
                try file.data.write(to: url, options: .atomic)
                done(.saved)
            } catch {
                done(.failed("couldn't save \(url.lastPathComponent): \(error.localizedDescription)"))
            }
        }
        return { [weak window] gone in
            window?.endSheet(panel)
            gone()
        }
    }
}

/// The photo picker as a sheet on the window's content view controller.
@MainActor
enum PhotoPicker {
    static func present(limit: Int, window: NSWindow, done: @escaping (DialogResult) -> Void) throws -> Close {
        guard let host = window.contentViewController else {
            throw DialogUnavailable(description: "there is no view controller to show the photo picker on")
        }
        let picker = photoPicker(limit: limit) { [weak host] picker, results in
            if picker.presentingViewController != nil { host?.dismiss(picker) }
            PhotoLoader.load(results.map(\.itemProvider), done: done)
        }
        if picker.preferredContentSize == .zero {
            picker.preferredContentSize = NSSize(width: 760, height: 560)
        }
        host.presentAsSheet(picker)
        return { [weak host, weak picker] gone in
            if let picker, picker.presentingViewController != nil { host?.dismiss(picker) }
            gone()
        }
    }
}

#else

/// The document picker, to open files (copied in) or save one.
@MainActor
enum FilePicker {
    static func open(types: [String], multiple: Bool, done: @escaping (DialogResult) -> Void) -> UIViewController {
        let contentTypes = types.compactMap { UTType($0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes.isEmpty ? [.item] : contentTypes, asCopy: true)
        picker.allowsMultipleSelection = multiple
        let delegate = DocumentPickerDelegate(
            picked: { urls in PickedFiles.readInBackground(urls, removeAfter: true, done: done) },
            cancelled: { done(.dismissed) }
        )
        picker.delegate = delegate
        retain(delegate, by: picker)
        return picker
    }

    /// `folders.pick`: one folder, opened in place (not copied), so the
    /// app can keep a bookmark to it.
    static func folder(done: @escaping (DialogResult) -> Void) -> UIViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        let delegate = DocumentPickerDelegate(
            picked: { urls in urls.first.map { done(.folder($0)) } ?? done(.dismissed) },
            cancelled: { done(.dismissed) }
        )
        picker.delegate = delegate
        retain(delegate, by: picker)
        return picker
    }

    /// `folders.pick({ write: true })`: the document picker takes no
    /// message, so an alert says first that the notebook may change and
    /// delete files there, and its Choose Folder shows the picker in its
    /// place. The alert is the controller the presenter shows and
    /// closes; closing it also closes the picker it led to.
    static func writeConsent(done: @escaping (DialogResult) -> Void) -> UIViewController {
        let picker = folder(done: done)
        let alert = ConsentAlert(
            title: "Let the notebook change files?",
            message: "The notebook will be able to read, change and delete files in the folder you choose next.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(.dismissed) })
        alert.addAction(UIAlertAction(title: "Choose Folder", style: .default) { [weak alert] _ in
            // Handlers run once the alert has gone, so its presenter is
            // free to show the picker.
            guard let alert, !alert.closed, let host = alert.host else { return done(.dismissed) }
            alert.picker = picker
            host.present(picker, animated: true)
        })
        return alert
    }

    static func export(_ file: NamedFile, done: @escaping (DialogResult) -> Void) throws -> UIViewController {
        let temp = try TemporaryFiles([file])
        let picker = UIDocumentPickerViewController(forExporting: temp.urls, asCopy: true)
        // The delegate lives as long as the picker and removes the copy when
        // it goes, which also covers a picker closed from code (interrupt),
        // where neither callback runs.
        let delegate = DocumentPickerDelegate(
            picked: { _ in done(.saved) },
            cancelled: { done(.dismissed) },
            temp: temp
        )
        picker.delegate = delegate
        retain(delegate, by: picker)
        return picker
    }
}

private final class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let picked: ([URL]) -> Void
    let cancelled: () -> Void
    let temp: TemporaryFiles?
    private var answered = false

    init(picked: @escaping ([URL]) -> Void, cancelled: @escaping () -> Void, temp: TemporaryFiles? = nil) {
        self.picked = picked
        self.cancelled = cancelled
        self.temp = temp
    }

    deinit {
        temp?.remove()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !answered else { return }
        answered = true
        picked(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !answered else { return }
        answered = true
        cancelled()
    }
}

/// The photo picker, answering once it has gone and the photos are read.
@MainActor
enum PhotoPicker {
    static func controller(limit: Int, done: @escaping (DialogResult) -> Void) -> UIViewController {
        photoPicker(limit: limit) { picker, results in
            let providers = results.map(\.itemProvider)
            if picker.presentingViewController != nil {
                picker.dismiss(animated: true) { PhotoLoader.load(providers, done: done) }
            } else {
                PhotoLoader.load(providers, done: done)
            }
        }
    }
}

/// The alert before a write folder pick. It remembers what showed it and
/// the picker it led to, so the presenter's close reaches the picker.
final class ConsentAlert: UIAlertController {
    weak var host: UIViewController?
    var picker: UIViewController?
    /// Set when the dialog is closed from code, so Choose Folder shows
    /// nothing after.
    var closed = false

    /// What is on screen for this dialog: the picker once it is up.
    var shown: UIViewController {
        if let picker, picker.presentingViewController != nil { return picker }
        return self
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        host = presentingViewController
    }
}

#endif
