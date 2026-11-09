import Foundation

// Native handles (docs/protocol.md, "Handles"): something a call opened
// that outlives the call, such as a sound player, which later calls name
// by id. Each belongs to the kernel that opened it (the call's `owner`)
// and lives as long as streams do: `release`, a new `hello` from that
// owner, `dropPage()`, `dropRemote()` and `dropAll()` close it, and so
// does a cancel of the call that opened it, since the page dropped that
// answer and has no id to close it with. `handle.close` closes one.

/// The handles a bridge has open.
@MainActor
final class Handles {
    private struct Entry {
        let owner: Int
        let kind: String
        let close: () -> Void
    }

    private var entries: [Int: Entry] = [:]
    /// The handle each opening call made, by call id, while it is open.
    private var openedBy: [Int: Int] = [:]
    private var nextID = 1

    /// Opens a handle of `kind` for `owner`, or answers nil when the owner
    /// already has `limit` of that kind open. `close` runs once, when the
    /// handle closes for any reason; it gets the handle's id. `call` is
    /// the opening call's id, so that its cancel closes the handle.
    func open(owner: Int, kind: String, limit: Int, call: Int?, close: @escaping (Int) -> Void) -> Int? {
        guard count(owner: owner, kind: kind) < limit else { return nil }
        let id = nextID
        nextID += 1
        entries[id] = Entry(owner: owner, kind: kind, close: { close(id) })
        if let call { openedBy[call] = id }
        return id
    }

    /// Whether `id` is an open handle of `kind` that `owner` opened.
    /// Another kernel's handle is no handle at all to this one.
    func isOpen(_ id: Int, owner: Int, kind: String) -> Bool {
        entries[id].map { $0.owner == owner && $0.kind == kind } ?? false
    }

    /// How many handles of `kind` `owner` has open.
    func count(owner: Int, kind: String) -> Int {
        entries.values.filter { $0.owner == owner && $0.kind == kind }.count
    }

    /// Closes `id` if `owner` opened it (and it is of `kind`, when given).
    /// Closing one already closed, or another kernel's, does nothing.
    func close(_ id: Int, owner: Int, kind: String? = nil) {
        guard let entry = entries[id], entry.owner == owner, kind.map({ $0 == entry.kind }) ?? true else { return }
        close(id)
    }

    /// The page cancelled call `call`: closes what it opened.
    func cancel(_ call: Int) {
        if let id = openedBy[call] { close(id) }
    }

    /// Closes the handles of each owner that `matches`.
    func stop(_ matches: (Int) -> Bool) {
        for (id, entry) in entries where matches(entry.owner) {
            close(id)
        }
    }

    /// Takes the entry out before its `close` runs, so a `close` that
    /// reaches back in finds it gone.
    private func close(_ id: Int) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        openedBy = openedBy.filter { $0.value != id }
        entry.close()
    }
}
