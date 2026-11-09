import Foundation

// `device.folders` (docs/protocol.md, "Folders"): a notebook keeps access
// to a folder the person picked. `folders.pick` shows the system folder
// picker, which is the consent, so there is no permission or ledger
// prompt. What was picked is kept as a bookmark, per notebook path, in a
// `FolderStore`; `notebookMoved` carries it and a Settings screen lists
// and revokes it through `FolderGrants`. Each call names a folder by its
// grant id and a path relative to it, and may not leave it: `..`, an
// absolute path, or a symlink that resolves outside fails `denied`. The
// app turns it on with `DeviceBridge.addFolders()`.

/// A folder a notebook was given.
public struct FolderGrant: Hashable, Sendable {
    /// The id the notebook names it by.
    public let id: String
    /// The notebook's path, as `setNotebook` gave it.
    public let notebook: String
    /// The folder's name, as the picker showed it.
    public let name: String
    /// Whether the person picked it for writing too.
    public let writable: Bool
    /// The bookmark that finds it again.
    public let bookmark: Data

    public init(id: String, notebook: String, name: String, writable: Bool, bookmark: Data) {
        self.id = id
        self.notebook = notebook
        self.name = name
        self.writable = writable
        self.bookmark = bookmark
    }

    func with(notebook: String? = nil, bookmark: Data? = nil) -> FolderGrant {
        FolderGrant(id: id, notebook: notebook ?? self.notebook, name: name, writable: writable, bookmark: bookmark ?? self.bookmark)
    }
}

/// Where folder grants live, behind a protocol so tests needn't touch
/// UserDefaults.
@MainActor
public protocol FolderStore {
    func load() -> [FolderGrant]
    func save(_ grants: [FolderGrant])
}

/// UserDefaults, under one key.
@MainActor
public struct UserDefaultsFolderStore: FolderStore {
    public let key: String
    public let defaults: UserDefaults

    public init(key: String = "ganymede.device.folders", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    public func load() -> [FolderGrant] {
        let rows = defaults.array(forKey: key) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let notebook = row["notebook"] as? String,
                  let name = row["name"] as? String, let writable = row["writable"] as? Bool,
                  let bookmark = row["bookmark"] as? Data
            else { return nil }
            return FolderGrant(id: id, notebook: notebook, name: name, writable: writable, bookmark: bookmark)
        }
    }

    public func save(_ grants: [FolderGrant]) {
        defaults.set(
            grants.map { ["id": $0.id, "notebook": $0.notebook, "name": $0.name, "writable": $0.writable, "bookmark": $0.bookmark] as [String: Any] },
            forKey: key)
    }
}

/// The folders notebooks were given. Instances on one store share them,
/// as `PermissionLedger`s do: each read goes to the store, so a Settings
/// screen's instance sees what a bridge's added.
@MainActor
public final class FolderGrants {
    private let store: FolderStore

    public init(store: FolderStore? = nil) {
        self.store = store ?? UserDefaultsFolderStore()
    }

    /// Every grant, for a Settings screen.
    public var grants: [FolderGrant] { store.load() }

    /// `notebook`'s grants, in the order they were picked.
    public func grants(for notebook: String) -> [FolderGrant] {
        grants.filter { $0.notebook == notebook }
    }

    /// Takes grant `id` away; the notebook's next call naming it fails `denied`.
    public func revoke(_ id: String) {
        store.save(grants.filter { $0.id != id })
    }

    /// Takes every one of `notebook`'s grants away.
    public func revoke(notebook: String) {
        store.save(grants.filter { $0.notebook != notebook })
    }

    /// A notebook was renamed or moved: its grants follow.
    public func move(from old: String, to new: String) {
        guard old != new else { return }
        let rows = grants
        guard rows.contains(where: { $0.notebook == old }) else { return }
        store.save(rows.map { $0.notebook == old ? $0.with(notebook: new) : $0 })
    }

    func grant(_ id: String, notebook: String) -> FolderGrant? {
        grants.first { $0.id == id && $0.notebook == notebook }
    }

    /// Keeps `grant`, in place of one with its id.
    func keep(_ grant: FolderGrant) {
        var rows = grants
        if let index = rows.firstIndex(where: { $0.id == grant.id }) {
            rows[index] = grant
        } else {
            rows.append(grant)
        }
        store.save(rows)
    }
}

/// Finding a granted folder, and paths in it. Nonisolated: everything
/// here but `bookmark` runs off the main thread.
enum FolderAccess {
    /// A bookmark to `url`, which the picker just handed over.
    static func bookmark(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        // A security scope where the app is sandboxed; a plain bookmark
        // where it isn't, since a scope there needs the sandbox's
        // bookmarks entitlement.
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data
        }
        #endif
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Why a bookmark didn't find its folder.
    enum Missing: Error {
        /// The bookmark data itself is unusable: drop the grant.
        case unusable
        /// Not reachable now (a volume not mounted, a file provider not
        /// ready, the folder moved away): keep the grant.
        case unreachable
    }

    /// Where `bookmark` points now, and whether it should be made again.
    /// Never shows UI or mounts a volume, so an unreachable share fails
    /// at once instead of waiting.
    static func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let quiet: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        #if os(macOS)
        if let url = try? URL(resolvingBookmarkData: bookmark, options: quiet.union(.withSecurityScope), relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        #endif
        do {
            let url = try URL(resolvingBookmarkData: bookmark, options: quiet, relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        } catch CocoaError.fileReadCorruptFile {
            throw Missing.unusable
        } catch {
            throw Missing.unreachable
        }
    }

    /// The real path of `url`, symlinks resolved, inside its security
    /// scope; nil when nothing is there.
    static func realPath(of url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return realPath(url.path)
    }

    /// The real path of `path`, symlinks resolved, or nil when nothing is there.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path` in the folder at `root`: refused `denied` when it is
    /// absolute, has a `..`, or resolves outside the folder. Symlinks are
    /// resolved, all of them with `followLast`, or all but the last
    /// component without it, so `remove` takes away a link and not what
    /// it points to. A path that doesn't exist yet resolves through its
    /// nearest ancestor that does.
    static func target(root: URL, path: String, followLast: Bool = true) throws -> URL {
        guard !path.hasPrefix("/") else {
            throw DeviceCallError("denied", "\(path) is absolute; paths are relative to the folder")
        }
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !parts.contains("..") else {
            throw DeviceCallError("denied", "\(path) has a .., which could leave the folder")
        }
        guard let base = realPath(root.path) else {
            throw DeviceCallError("unavailable", "the folder isn't there any more")
        }
        let last = followLast ? nil : parts.popLast()
        // The nearest ancestor that exists, resolved, with the rest after it.
        var existing = parts
        var rest: [String] = []
        var resolved: String?
        while resolved == nil {
            let candidate = ([base] + existing).joined(separator: "/")
            if let real = realPath(candidate) {
                resolved = real
            } else if let next = existing.popLast() {
                rest.insert(next, at: 0)
            } else {
                resolved = base
            }
        }
        let full = ([resolved!] + rest).joined(separator: "/")
        guard full == base || full.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
            throw DeviceCallError("denied", "\(path) leaves the folder")
        }
        return URL(fileURLWithPath: last.map { full + "/" + $0 } ?? full)
    }

    static let maxRead = DeviceBridge.maxBinaryBytes

    /// Runs `body` on `url` as a coordinated read, which also brings an
    /// iCloud Drive file down when only its placeholder is here.
    static func reading<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinated: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinated) { url in
            result = Result { try body(url) }
        }
        if let coordinated { throw coordinated }
        return try result!.get()
    }

    /// Runs `body` on `url` as a coordinated write (`.forDeleting` for a remove).
    static func writing(_ url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void) throws {
        var coordinated: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinated) { url in
            do { try body(url) } catch { failure = error }
        }
        if let coordinated { throw coordinated }
        if let failure { throw failure }
    }

    /// An iCloud Drive placeholder's name for `name`: `.name.icloud`.
    static func placeholder(_ name: String) -> String { "." + name + ".icloud" }

    /// `url`, or when only its iCloud Drive placeholder is here, still
    /// `url`: a coordinated read downloads it.
    static func exists(_ url: URL) -> (exists: Bool, directory: Bool) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return (true, isDirectory.boolValue)
        }
        let stub = url.deletingLastPathComponent().appendingPathComponent(placeholder(url.lastPathComponent))
        return (FileManager.default.fileExists(atPath: stub.path), false)
    }

    static func entries(_ url: URL) throws -> [[String: Any]] {
        let found = exists(url)
        guard found.exists else { throw DeviceCallError("failed", "there is nothing at \(url.lastPathComponent)") }
        guard found.directory else { throw DeviceCallError("failed", "\(url.lastPathComponent) isn't a directory") }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let items = try reading(url) { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: keys, options: []) }
        var entries: [String: [String: Any]] = [:]
        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let directory = values?.isDirectory ?? false
            var name = item.lastPathComponent
            // An iCloud Drive file not downloaded yet: list it by its own
            // name, without a size, unless the file is here too.
            if name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 {
                name = String(name.dropFirst().dropLast(".icloud".count))
                guard entries[name] == nil else { continue }
                entries[name] = ["name": name, "kind": "file"]
                continue
            }
            var entry: [String: Any] = ["name": name, "kind": directory ? "directory" : "file"]
            if !directory, let size = values?.fileSize { entry["size"] = size }
            if let modified = values?.contentModificationDate { entry["modified"] = Dialog.formatDate(modified) }
            entries[name] = entry
        }
        return entries.keys.sorted().map { entries[$0]! }
    }

    static func read(_ url: URL) throws -> Data {
        let found = exists(url)
        guard found.exists else { throw DeviceCallError("failed", "there is nothing at \(url.lastPathComponent)") }
        guard !found.directory else { throw DeviceCallError("failed", "\(url.lastPathComponent) is a directory; use entries()") }
        return try reading(url) { url in
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maxRead else {
                throw DeviceCallError("failed", "\(url.lastPathComponent) is \(size) bytes; reads are limited to \(maxRead)")
            }
            return try Data(contentsOf: url)
        }
    }

    /// Replaces what is at `url` (a symlink there is replaced, not
    /// followed), making the directories on the way.
    static func write(_ data: Data, to url: URL) throws {
        if (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory {
            throw DeviceCallError("failed", "\(url.lastPathComponent) is a directory")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writing(url, options: .forReplacing) { try data.write(to: $0, options: .atomic) }
    }

    /// A file, a symlink (not what it points to), or an empty directory:
    /// nothing that takes more with it.
    static func remove(_ url: URL) throws {
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        guard let type else {
            throw DeviceCallError("failed", "there is nothing at \(url.lastPathComponent)")
        }
        if type == .typeDirectory, !(try FileManager.default.contentsOfDirectory(atPath: url.path)).isEmpty {
            throw DeviceCallError("failed", "\(url.lastPathComponent) isn't empty; remove what is in it first")
        }
        try writing(url, options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
    }
}

extension DeviceBridge {
    /// Turns on `device.folders`: `folders.pick` (the system folder
    /// picker), `folders.list`, and `entries`, `read`, `write` and
    /// `remove` in a picked folder. `grants` keeps what was picked; the
    /// default is UserDefaults, which a Settings screen's `FolderGrants()`
    /// shares.
    public func addFolders(_ grants: FolderGrants? = nil) {
        let grants = grants ?? FolderGrants()
        folderGrants = grants
        addDialog("folders.pick", prepare: { context in
            _ = try Self.notebook(context, "folders.pick")
        }, finish: { answer, params, context in
            guard case let .folder(url) = answer else { return NSNull() }
            let notebook = try Self.notebook(context, "folders.pick")
            let writable = params["write"] as? Bool ?? false
            return Self.folderReply(try Self.keep(url, writable: writable, notebook: notebook, grants: grants))
        })
        addMethod("folders.list", contextHandler: { _, context, reply in
            do {
                let notebook = try Self.notebook(context, "folders.list")
                reply(.success(grants.grants(for: notebook).map(Self.folderReply)))
            } catch {
                reply(.failure(Self.callError(error, "folders.list")))
            }
            return nil
        })
        addFolderMethod("folders.entries", grants: grants, writes: false, needsPath: false) { root, path, _ in
            try FolderAccess.entries(try FolderAccess.target(root: root, path: path))
        }
        addFolderMethod("folders.read", grants: grants, writes: false) { root, path, _ in
            try DeviceBridge.binary(try FolderAccess.read(try FolderAccess.target(root: root, path: path)))
        }
        addFolderMethod("folders.write", grants: grants, writes: true, check: { params in
            // The shape and size only: the bytes are decoded off the main thread.
            guard let data = params["data"] as? [String: Any], let text = data["base64"] as? String else {
                throw DeviceCallError("failed", "folders.write needs data as bytes ({ base64 })")
            }
            guard text.utf8.count <= (DeviceBridge.maxBinaryBytes + 2) / 3 * 4 else {
                throw DeviceCallError("failed", "folders.write: data is over \(DeviceBridge.maxBinaryBytes) bytes")
            }
        }) { root, path, params in
            let data: Data
            do {
                data = try DeviceBridge.bytes(params["data"])
            } catch {
                throw DeviceCallError("failed", "folders.write: \(error)")
            }
            try FolderAccess.write(data, to: try FolderAccess.target(root: root, path: path, followLast: false))
            return NSNull()
        }
        addFolderMethod("folders.remove", grants: grants, writes: true) { root, path, _ in
            try FolderAccess.remove(try FolderAccess.target(root: root, path: path, followLast: false))
            return NSNull()
        }
    }

    /// A call on one granted folder: `{ folder, path }`. It finds the
    /// grant for the caller's notebook, then off the main thread resolves
    /// its bookmark and runs `body` with the folder and the path, inside
    /// the folder's security scope. A stale bookmark is made again; one
    /// whose data is unusable is dropped; an unreachable folder fails
    /// `unavailable` and keeps its grant.
    private func addFolderMethod(
        _ method: String, grants: FolderGrants, writes: Bool, needsPath: Bool = true, check: ParamsCheck? = nil,
        body: @escaping @Sendable (_ root: URL, _ path: String, _ params: [String: Any]) throws -> Any
    ) {
        addMethod(method, check: { params in
            guard let id = params["folder"] as? String, !id.isEmpty else {
                throw DeviceCallError("failed", "\(method) needs a folder id")
            }
            let path = params["path"]
            if needsPath || !(path == nil || path is NSNull) {
                guard let text = path as? String, !needsPath || !text.isEmpty else {
                    throw DeviceCallError("failed", "\(method) needs a path in the folder")
                }
            }
            try check?(params)
        }, contextHandler: { params, context, reply in
            let grant: FolderGrant
            let path = params["path"] as? String ?? ""
            do {
                let notebook = try Self.notebook(context, method)
                guard let id = params["folder"] as? String, let found = grants.grant(id, notebook: notebook) else {
                    throw DeviceCallError("denied", "\(method): this notebook has no such folder (it was revoked, or picked by another notebook)")
                }
                if writes, !found.writable {
                    throw DeviceCallError("denied", "\(method): \(found.name) was picked for reading only; pick it again with write: true")
                }
                if writes, path.split(separator: "/").allSatisfy({ $0 == "." }) {
                    throw DeviceCallError("denied", "\(method): that is the folder itself")
                }
                grant = found
            } catch {
                reply(.failure(Self.callError(error, method)))
                return nil
            }
            // `params` crosses to the work queue as what it holds: strings
            // and `{ base64 }` bytes.
            let sent = Unchecked(params)
            DispatchQueue.global(qos: .userInitiated).async {
                var fresh: Data?
                var drop = false
                let result: Result<Unchecked, DeviceCallError> = Result {
                    let resolved: (url: URL, stale: Bool)
                    do {
                        resolved = try FolderAccess.resolve(grant.bookmark)
                    } catch FolderAccess.Missing.unusable {
                        drop = true
                        throw DeviceCallError("unavailable", "\(grant.name)'s bookmark can't be read; pick it again")
                    } catch {
                        throw DeviceCallError("unavailable", "\(grant.name) can't be reached now (a disconnected drive or share, or a file provider not ready)")
                    }
                    let root = resolved.url
                    let scoped = root.startAccessingSecurityScopedResource()
                    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                    guard FolderAccess.exists(root).directory else {
                        throw DeviceCallError("unavailable", "\(grant.name) isn't there now; pick it again if it moved")
                    }
                    if resolved.stale { fresh = try? FolderAccess.bookmark(root) }
                    return Unchecked(try body(root, path, sent.value as! [String: Any]))
                }.mapError { Self.callError($0, method) }
                let refreshed = fresh
                let dropped = drop
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if dropped { grants.revoke(grant.id) }
                        if let refreshed, let current = grants.grant(grant.id, notebook: grant.notebook) {
                            grants.keep(current.with(bookmark: refreshed))
                        }
                        reply(result.map(\.value))
                    }
                }
            }
            return nil
        })
    }

    /// Keeps the picked `url` for `notebook`, in place of the notebook's
    /// earlier grant of the same folder, which keeps its id.
    private static func keep(_ url: URL, writable: Bool, notebook: String, grants: FolderGrants) throws -> FolderGrant {
        let bookmark: Data
        do {
            bookmark = try FolderAccess.bookmark(url)
        } catch {
            throw DeviceCallError("failed", "folders.pick: couldn't keep access to \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let path = FolderAccess.realPath(of: url) ?? url.standardizedFileURL.path
        let earlier = grants.grants(for: notebook).first { grant in
            guard let other = (try? FolderAccess.resolve(grant.bookmark))?.url else { return false }
            return (FolderAccess.realPath(of: other) ?? other.standardizedFileURL.path) == path
        }
        let grant = FolderGrant(
            id: earlier?.id ?? UUID().uuidString, notebook: notebook, name: url.lastPathComponent,
            writable: writable, bookmark: bookmark)
        grants.keep(grant)
        return grant
    }

    /// The notebook a folder call's kernel runs; without one, nothing to
    /// keep a folder for.
    private static func notebook(_ context: CallContext, _ method: String) throws -> String {
        guard let notebook = context.notebook else {
            throw DeviceCallError("denied", "\(method): the app hasn't said which notebook this kernel runs")
        }
        return notebook
    }

    private static func folderReply(_ grant: FolderGrant) -> [String: Any] {
        ["id": grant.id, "name": grant.name, "writable": grant.writable]
    }

    private nonisolated static func callError(_ error: Error, _ method: String) -> DeviceCallError {
        if let error = error as? DeviceCallError { return error }
        return DeviceCallError("failed", "\(method): \(error.localizedDescription)")
    }
}

/// A call's params or a reply value, which hold only property-list values
/// (strings, numbers, arrays, dictionaries), handed between queues.
private struct Unchecked: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}
