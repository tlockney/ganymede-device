import Foundation
import Security

// `device.secrets` (docs/protocol.md, "Secrets"): strings a notebook keeps
// in the keychain, on this device only. Each is a generic password under
// service `ganymede.device.secrets`, account `<notebook path>\0<name>`, so
// a notebook sees only its own; `notebookMoved` re-keys them. There is no
// system permission, so the ledger's prompt (capability `secrets`) is the
// only consent. The app turns it on with `DeviceBridge.addSecrets()`, and
// a Settings screen lists and deletes them through `NotebookSecrets`.

/// Where secrets live, behind a protocol so tests needn't touch the
/// keychain. An account is `<notebook>\0<name>`.
@MainActor
public protocol SecretStore {
    /// The value, or nil when there is none.
    func read(_ account: String) throws -> String?
    /// Saves `value`, in place of what the account held.
    func write(_ value: String, to account: String) throws
    /// Whether there was one to delete.
    func delete(_ account: String) throws -> Bool
    /// Every account the store holds.
    func accounts() throws -> [String]
}

/// A secret store that can't be reached now: before the device's first
/// unlock since it started, the keychain refuses. Calls fail
/// `unavailable`.
public struct SecretStoreLocked: Error {
    public init() {}
}

/// One notebook's secret, as a Settings screen lists it: never the value.
public struct NotebookSecret: Hashable, Sendable {
    public let notebook: String
    public let name: String
}

/// The secrets notebooks saved. Instances on one store share them, as
/// `FolderGrants` do: each read goes to the store.
@MainActor
public final class NotebookSecrets {
    private let store: SecretStore

    public init(store: SecretStore? = nil) {
        self.store = store ?? KeychainSecretStore()
    }

    static func account(_ notebook: String, _ name: String) -> String { "\(notebook)\0\(name)" }

    static func split(_ account: String) -> NotebookSecret? {
        guard let cut = account.firstIndex(of: "\0") else { return nil }
        return NotebookSecret(notebook: String(account[..<cut]), name: String(account[account.index(after: cut)...]))
    }

    /// Every secret's notebook and name, for a Settings screen. Empty when
    /// the store can't be read.
    public var all: [NotebookSecret] {
        ((try? store.accounts()) ?? []).compactMap(Self.split).sorted { ($0.notebook, $0.name) < ($1.notebook, $1.name) }
    }

    /// `notebook`'s names, sorted.
    public func names(for notebook: String) throws -> [String] {
        try store.accounts().compactMap(Self.split).filter { $0.notebook == notebook }.map(\.name).sorted()
    }

    public func value(_ name: String, notebook: String) throws -> String? {
        try store.read(Self.account(notebook, name))
    }

    public func save(_ value: String, name: String, notebook: String) throws {
        try store.write(value, to: Self.account(notebook, name))
    }

    /// Deletes one; whether it was there.
    @discardableResult
    public func delete(_ name: String, notebook: String) throws -> Bool {
        try store.delete(Self.account(notebook, name))
    }

    /// Deletes every one of `notebook`'s secrets.
    public func delete(notebook: String) throws {
        for name in try names(for: notebook) { try delete(name, notebook: notebook) }
    }

    /// A notebook was renamed or moved: its secrets follow. One the new
    /// path already has keeps the new path's value.
    public func move(from old: String, to new: String) throws {
        guard old != new else { return }
        for name in try names(for: old) {
            if try value(name, notebook: new) == nil, let value = try value(name, notebook: old) {
                try save(value, name: name, notebook: new)
            }
            try delete(name, notebook: old)
        }
    }
}

/// The keychain: generic passwords, this device only, readable after the
/// first unlock since it started (so a headless run can read them while
/// the device is locked), never synced. On the Mac the queries use the
/// data protection keychain, where those classes apply. `accessGroup`
/// shares them with the app's extensions; the app and each extension need
/// `keychain-access-groups` with it, or every call fails.
@MainActor
public struct KeychainSecretStore: SecretStore {
    public static let service = "ganymede.device.secrets"
    public let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    private func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrSynchronizable as String: false,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecInteractionNotAllowed: throw SecretStoreLocked()
        default:
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            throw DeviceCallError("failed", "the keychain refused: \(message)")
        }
    }

    public func read(_ account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw DeviceCallError("failed", "the keychain item isn't text")
        }
        return value
    }

    public func write(_ value: String, to account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecItemNotFound { return try check(status) }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try check(SecItemAdd(item as CFDictionary, nil))
    }

    public func delete(_ account: String) throws -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    public func accounts() throws -> [String] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        return (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

extension DeviceBridge {
    /// The longest secret value, in UTF-8 bytes.
    static let maxSecretBytes = 64 * 1024

    /// Turns on `device.secrets`: `secrets.get`, `set`, `delete` and
    /// `list`, under capability `secrets`, which has no system permission.
    /// `secrets` keeps them; the default is the keychain, which a Settings
    /// screen's `NotebookSecrets()` shares.
    public func addSecrets(_ secrets: NotebookSecrets? = nil) {
        let secrets = secrets ?? NotebookSecrets()
        notebookSecrets = secrets
        addPermission("secrets", LedgerOnlyPermission())
        func run(_ method: String, _ context: CallContext, reply: MethodReply, _ body: (String) throws -> Any) {
            do {
                guard let notebook = context.notebook else {
                    throw DeviceCallError("denied", "\(method): the app hasn't said which notebook this kernel runs")
                }
                reply(.success(try body(notebook)))
            } catch is SecretStoreLocked {
                reply(.failure(DeviceCallError("unavailable", "\(method): the keychain is locked until the device is first unlocked")))
            } catch {
                reply(.failure(error as? DeviceCallError ?? DeviceCallError("failed", "\(method): \(error.localizedDescription)")))
            }
        }
        addMethod("secrets.get", permission: "secrets", check: { _ = try Self.secretName("secrets.get", $0) }, contextHandler: { params, context, reply in
            run("secrets.get", context, reply: reply) { notebook in
                let value = try secrets.value(try Self.secretName("secrets.get", params), notebook: notebook)
                return value.map { $0 as Any } ?? NSNull()
            }
            return nil
        })
        addMethod("secrets.set", permission: "secrets", check: { _ = try Self.secretValue($0) }, contextHandler: { params, context, reply in
            run("secrets.set", context, reply: reply) { notebook in
                try secrets.save(try Self.secretValue(params), name: try Self.secretName("secrets.set", params), notebook: notebook)
                return NSNull()
            }
            return nil
        })
        addMethod("secrets.delete", permission: "secrets", check: { _ = try Self.secretName("secrets.delete", $0) }, contextHandler: { params, context, reply in
            run("secrets.delete", context, reply: reply) { notebook in
                try secrets.delete(try Self.secretName("secrets.delete", params), notebook: notebook)
            }
            return nil
        })
        addMethod("secrets.list", permission: "secrets", contextHandler: { _, context, reply in
            run("secrets.list", context, reply: reply) { notebook in try secrets.names(for: notebook) }
            return nil
        })
    }

    static func secretName(_ method: String, _ params: [String: Any]) throws -> String {
        // UTF-16 code units, as the cell's `name.length` counts them.
        guard let name = params["name"] as? String, (1...128).contains(name.utf16.count), !name.contains("\0") else {
            throw DeviceCallError("failed", "\(method) needs a name of 1 to 128 characters, without NUL")
        }
        return name
    }

    /// `secrets.set`'s value, after checking its name.
    static func secretValue(_ params: [String: Any]) throws -> String {
        _ = try secretName("secrets.set", params)
        guard let value = params["value"] as? String else {
            throw DeviceCallError("failed", "secrets.set: the value must be a string")
        }
        guard value.utf8.count <= maxSecretBytes else {
            throw DeviceCallError("failed", "secrets.set: the value is over \(maxSecretBytes) bytes")
        }
        return value
    }
}
