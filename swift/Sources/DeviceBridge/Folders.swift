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

/// Finding a granted folder, and paths in it. Nonisolated: the reads and
/// writes run off the main thread.
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

    /// Where `bookmark` points now, and whether it should be made again.
    static func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        #if os(macOS)
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        #endif
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    /// The real path of `path`, symlinks resolved, or nil when nothing is there.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path` in the folder at `root`, symlinks resolved: refused
    /// `denied` when it is absolute, has a `..`, or resolves outside the
    /// folder. A path that doesn't exist yet resolves through its nearest
    /// ancestor that does.
    static func target(root: URL, path: String) throws -> URL {
        guard !path.hasPrefix("/") else {
            throw DeviceCallError("denied", "\(path) is absolute; paths are relative to the folder")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !parts.contains("..") else {
            throw DeviceCallError("denied", "\(path) has a .., which could leave the folder")
        }
        guard let base = realPath(root.path) else {
            throw DeviceCallError("unavailable", "the folder isn't there any more")
        }
        // The nearest ancestor that exists, resolved, with the rest after it.
        var existing = parts
        var rest: [String] = []
        var resolved: String?
        while resolved == nil {
            let candidate = ([base] + existing).joined(separator: "/")
            if let real = realPath(candidate) {
                resolved = real
            } else if let last = existing.popLast() {
                rest.insert(last, at: 0)
            } else {
                resolved = base
            }
        }
        let full = ([resolved!] + rest).joined(separator: "/")
        guard full == base || full.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
            throw DeviceCallError("denied", "\(path) leaves the folder")
        }
        return URL(fileURLWithPath: full)
    }

    static let maxRead = DeviceBridge.maxBinaryBytes

    static func entries(_ url: URL) throws -> [[String: Any]] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw DeviceCallError("failed", "there is nothing at \(url.lastPathComponent)")
        }
        guard isDirectory.boolValue else {
            throw DeviceCallError("failed", "\(url.lastPathComponent) isn't a directory")
        }
        let found = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            let directory = values?.isDirectory ?? false
            var entry: [String: Any] = ["name": item.lastPathComponent, "kind": directory ? "directory" : "file"]
            if !directory, let size = values?.fileSize { entry["size"] = size }
            if let modified = values?.contentModificationDate { entry["modified"] = Dialog.formatDate(modified) }
            return entry
        }
    }

    static func read(_ url: URL) throws -> Data {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw DeviceCallError("failed", "there is nothing at \(url.lastPathComponent)")
        }
        guard !isDirectory.boolValue else {
            throw DeviceCallError("failed", "\(url.lastPathComponent) is a directory; use entries()")
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxRead else {
            throw DeviceCallError("failed", "\(url.lastPathComponent) is \(size) bytes; reads are limited to \(maxRead)")
        }
        return try Data(contentsOf: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw DeviceCallError("failed", "\(url.lastPathComponent) is a directory")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// A file, or an empty directory: nothing that takes more with it.
    static func remove(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw DeviceCallError("failed", "there is nothing at \(url.lastPathComponent)")
        }
        if isDirectory.boolValue, !(try FileManager.default.contentsOfDirectory(atPath: url.path)).isEmpty {
            throw DeviceCallError("failed", "\(url.lastPathComponent) isn't empty; remove what is in it first")
        }
        try FileManager.default.removeItem(at: url)
    }
}

/// What `folders.pick`'s dialog handed over.
struct PickedFolder {
    let url: URL
    let writable: Bool
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
        }, finish: { result, context in
            guard let picked = result as? PickedFolder else { return NSNull() }
            let notebook = try Self.notebook(context, "folders.pick")
            return Self.folderReply(try Self.keep(picked, notebook: notebook, grants: grants))
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
        addFolderMethod("folders.entries", grants: grants, writes: false) { url, _ in
            try FolderAccess.entries(url)
        }
        addFolderMethod("folders.read", grants: grants, writes: false) { url, _ in
            try DeviceBridge.binary(try FolderAccess.read(url))
        }
        addFolderMethod("folders.write", grants: grants, writes: true, check: { params in
            do {
                _ = try DeviceBridge.bytes(params["data"])
            } catch {
                throw DeviceCallError("failed", "folders.write: \(error)")
            }
        }) { url, params in
            try FolderAccess.write(try DeviceBridge.bytes(params["data"]), to: url)
            return NSNull()
        }
        addFolderMethod("folders.remove", grants: grants, writes: true) { url, _ in
            try FolderAccess.remove(url)
            return NSNull()
        }
    }

    /// A call on one granted folder: `{ folder, path }`. It finds the
    /// grant for the caller's notebook, resolves its bookmark (making it
    /// again when stale, dropping it when it no longer resolves), and runs
    /// `body` off the main thread on the path in it, inside the folder's
    /// security scope.
    private func addFolderMethod(
        _ method: String, grants: FolderGrants, writes: Bool, check: ParamsCheck? = nil,
        body: @escaping @Sendable (URL, [String: Any]) throws -> Any
    ) {
        let needsPath = method != "folders.entries"
        addMethod(method, check: { params in
            guard let id = params["folder"] as? String, !id.isEmpty else {
                throw DeviceCallError("failed", "\(method) needs a folder id")
            }
            let path = params["path"]
            if needsPath || !(path == nil || path is NSNull) {
                guard let path = path as? String, !needsPath || !path.isEmpty else {
                    throw DeviceCallError("failed", "\(method) needs a path in the folder")
                }
            }
            try check?(params)
        }, contextHandler: { params, context, reply in
            let root: URL
            let path = params["path"] as? String ?? ""
            do {
                let notebook = try Self.notebook(context, method)
                guard let id = params["folder"] as? String, let grant = grants.grant(id, notebook: notebook) else {
                    throw DeviceCallError("denied", "\(method): this notebook has no such folder (it was revoked, or picked by another notebook)")
                }
                if writes, !grant.writable {
                    throw DeviceCallError("denied", "\(method): \(grant.name) was picked for reading only; pick it again with write: true")
                }
                if writes, needsPath, path.split(separator: "/").allSatisfy({ $0 == "." }) {
                    throw DeviceCallError("denied", "\(method): that is the folder itself")
                }
                root = try Self.openGrant(grant, grants: grants)
            } catch {
                reply(.failure(Self.callError(error, method)))
                return nil
            }
            // `params` crosses to the work queue as what it holds: strings
            // and `{ base64 }` bytes.
            let sendable = SendableParams(params)
            DispatchQueue.global(qos: .userInitiated).async {
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                let result: Result<SendableValue, DeviceCallError> = Result {
                    SendableValue(try body(try FolderAccess.target(root: root, path: path), sendable.params))
                }.mapError { Self.callError($0, method) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { reply(result.map(\.value)) }
                }
            }
            return nil
        })
    }

    /// Where `grant` points now: a stale bookmark is made again, and one
    /// that no longer finds a folder is dropped.
    private static func openGrant(_ grant: FolderGrant, grants: FolderGrants) throws -> URL {
        let resolved: (url: URL, stale: Bool)
        do {
            resolved = try FolderAccess.resolve(grant.bookmark)
        } catch {
            grants.revoke(grant.id)
            throw DeviceCallError("unavailable", "\(grant.name) can't be found any more; pick it again")
        }
        var isDirectory: ObjCBool = false
        let scoped = resolved.url.startAccessingSecurityScopedResource()
        defer { if scoped { resolved.url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            grants.revoke(grant.id)
            throw DeviceCallError("unavailable", "\(grant.name) isn't there any more; pick it again")
        }
        if resolved.stale, let fresh = try? FolderAccess.bookmark(resolved.url) {
            grants.keep(grant.with(bookmark: fresh))
        }
        return resolved.url
    }

    /// Keeps `picked` for `notebook`, in place of the notebook's earlier
    /// grant of the same folder, which keeps its id.
    private static func keep(_ picked: PickedFolder, notebook: String, grants: FolderGrants) throws -> FolderGrant {
        let bookmark: Data
        do {
            bookmark = try FolderAccess.bookmark(picked.url)
        } catch {
            throw DeviceCallError("failed", "folders.pick: couldn't keep access to \(picked.url.lastPathComponent): \(error.localizedDescription)")
        }
        let path = FolderAccess.realPath(picked.url.path) ?? picked.url.standardizedFileURL.path
        let earlier = grants.grants(for: notebook).first { grant in
            guard let url = (try? FolderAccess.resolve(grant.bookmark))?.url else { return false }
            return (FolderAccess.realPath(url.path) ?? url.standardizedFileURL.path) == path
        }
        let grant = FolderGrant(
            id: earlier?.id ?? UUID().uuidString, notebook: notebook, name: picked.url.lastPathComponent,
            writable: picked.writable, bookmark: bookmark)
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
private struct SendableParams: @unchecked Sendable {
    let params: [String: Any]
    init(_ params: [String: Any]) { self.params = params }
}

private struct SendableValue: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}
