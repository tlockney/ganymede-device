import Foundation

// The app's permission ledger (docs/plan.md, "Permissions" item 2;
// docs/protocol.md, "The ledger"). Before a permissioned call reaches the
// system prompt, the app asks the person whether this notebook may use the
// capability: once, always, or deny. "Always" and "deny" are kept, keyed
// by (notebook path, capability); a Settings screen lists and revokes
// them. With no prompter (headless runs), a call with no grant is denied.
// Pickers, share and dialogs are their own consent and never reach it.

/// What the person answered the app's prompt. Nil (dismissed) denies this
/// call and records nothing.
public enum LedgerAnswer: String, Sendable {
    /// This call only; nothing is kept.
    case once
    /// This notebook, from now on.
    case always
    /// This notebook, from now on, until revoked.
    case deny
}

/// A kept answer.
public struct LedgerGrant: Hashable, Sendable {
    public let notebook: String
    public let capability: String
    /// `always` or `deny`.
    public let answer: LedgerAnswer

    public init(notebook: String, capability: String, answer: LedgerAnswer) {
        self.notebook = notebook
        self.capability = capability
        self.answer = answer
    }
}

/// Where kept answers live, behind a protocol so tests needn't touch
/// UserDefaults.
@MainActor
public protocol LedgerStore {
    func load() -> [LedgerGrant]
    func save(_ grants: [LedgerGrant])
}

/// UserDefaults, under one key.
@MainActor
public struct UserDefaultsLedgerStore: LedgerStore {
    public let key: String
    public let defaults: UserDefaults

    public init(key: String = "ganymede.device.ledger", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    public func load() -> [LedgerGrant] {
        let rows = defaults.array(forKey: key) as? [[String: String]] ?? []
        return rows.compactMap { row in
            guard let notebook = row["notebook"], let capability = row["capability"],
                  let answer = row["answer"].flatMap(LedgerAnswer.init(rawValue:)), answer != .once
            else { return nil }
            return LedgerGrant(notebook: notebook, capability: capability, answer: answer)
        }
    }

    public func save(_ grants: [LedgerGrant]) {
        defaults.set(grants.map { ["notebook": $0.notebook, "capability": $0.capability, "answer": $0.answer.rawValue] }, forKey: key)
    }
}

/// Shows the app's prompt. The app implements it: a sheet over the
/// notebook naming it and the capability, with once, always and deny.
@MainActor
public protocol LedgerPrompter: AnyObject {
    /// Ask whether `notebook` may use `capability`; call `answer` once,
    /// nil when dismissed. `id` names the prompt for `dismissPermission`.
    func askPermission(_ capability: String, notebook: String, id: Int, answer: @escaping @MainActor (LedgerAnswer?) -> Void)
    /// Close prompt `id` unanswered: every call waiting on it was cancelled.
    /// Its `answer` is then ignored.
    func dismissPermission(_ id: Int)
}

/// The kept answers, and the notebook each kernel runs.
@MainActor
public final class PermissionLedger {
    private let store: LedgerStore
    /// The notebook path each kernel (`owner`) runs, as the host said.
    private var notebooks: [Int: String] = [:]

    /// Ledgers on one store share their kept answers: each read goes to
    /// the store, so an app with a bridge per window, and a Settings
    /// screen with a ledger of its own, see one set of answers. Owners are
    /// per ledger, as they are per page.
    public init(store: LedgerStore? = nil) {
        self.store = store ?? UserDefaultsLedgerStore()
    }

    private var kept: [LedgerGrant] { store.load() }

    /// The kept answers, for a Settings screen.
    public var grants: [LedgerGrant] { kept }

    /// The kept answer for (`notebook`, `capability`): `always`, `deny`, or nil.
    public func answer(notebook: String, capability: String) -> LedgerAnswer? {
        kept.first { $0.notebook == notebook && $0.capability == capability }?.answer
    }

    /// Keeps `always` or `deny`; `once` keeps nothing.
    public func record(_ answer: LedgerAnswer, notebook: String, capability: String) {
        guard answer != .once else { return }
        var rows = kept
        rows.removeAll { $0.notebook == notebook && $0.capability == capability }
        rows.append(LedgerGrant(notebook: notebook, capability: capability, answer: answer))
        store.save(rows)
    }

    /// Forgets the answer for (`notebook`, `capability`), or every
    /// capability's for `notebook` when `capability` is nil. The next call
    /// asks again.
    public func revoke(notebook: String, capability: String? = nil) {
        var rows = kept
        rows.removeAll { $0.notebook == notebook && (capability == nil || $0.capability == capability) }
        store.save(rows)
    }

    /// Kernel `owner` runs `notebook` (a path), or none.
    public func setNotebook(_ notebook: String?, for owner: Int) {
        notebooks[owner] = notebook
    }

    /// The notebook kernel `owner` runs, as the host last said.
    public func notebook(for owner: Int) -> String? { notebooks[owner] }

    /// A notebook was renamed or moved: its kernels and kept answers
    /// follow, replacing answers left at `new` for the same capabilities
    /// (by a notebook deleted from there, say).
    public func move(from old: String, to new: String) {
        guard old != new else { return }
        for (owner, path) in notebooks where path == old {
            notebooks[owner] = new
        }
        var rows = kept
        let moving = Set(rows.filter { $0.notebook == old }.map(\.capability))
        guard !moving.isEmpty else { return }
        rows.removeAll { $0.notebook == new && moving.contains($0.capability) }
        rows = rows.map { $0.notebook == old ? LedgerGrant(notebook: new, capability: $0.capability, answer: $0.answer) : $0 }
        store.save(rows)
    }

    /// Of `declared` (a notebook's `metadata.ganymede.device` list), the
    /// capabilities with no kept answer, in order, without repeats, so the
    /// app can ask at open.
    public func undecided(_ declared: [String], notebook: String) -> [String] {
        var seen = Set<String>()
        return declared.filter { seen.insert($0).inserted && answer(notebook: notebook, capability: $0) == nil }
    }

    /// Forgets which notebook each owner that `matches` runs: its kernel
    /// is gone, and the number may come back for another notebook.
    func forget(owners matches: (Int) -> Bool) {
        notebooks = notebooks.filter { !matches($0.key) }
    }
}

/// The app prompts showing, one per (notebook, capability), so calls that
/// come while one is up wait on it.
@MainActor
final class LedgerRequests {
    private final class Prompt {
        let id: Int
        /// The notebook asked about; follows a rename while the prompt is up.
        var notebook: String
        let capability: String
        var waiters: [(call: Int, done: @MainActor (LedgerAnswer?) -> Void)] = []

        init(id: Int, notebook: String, capability: String) {
            self.id = id
            self.notebook = notebook
            self.capability = capability
        }
    }

    /// By prompt id.
    private var prompts: [Int: Prompt] = [:]
    private var nextID = 1

    /// Asks through `prompter`, or joins the prompt already up; `done` gets
    /// the answer, once. `record` keeps the answer once, under the prompt's
    /// own notebook (where a rename took it), before the waiters hear it.
    func ask(
        _ capability: String, notebook: String, call: Int, prompter: LedgerPrompter,
        record: @escaping @MainActor (_ answer: LedgerAnswer, _ notebook: String) -> Void,
        done: @escaping @MainActor (LedgerAnswer?) -> Void
    ) {
        if let prompt = prompts.values.first(where: { $0.notebook == notebook && $0.capability == capability }) {
            prompt.waiters.append((call, done))
            return
        }
        let prompt = Prompt(id: nextID, notebook: notebook, capability: capability)
        nextID += 1
        prompt.waiters.append((call, done))
        prompts[prompt.id] = prompt
        prompter.askPermission(capability, notebook: notebook, id: prompt.id) { [weak self, weak prompt] answer in
            guard let self, let prompt, self.prompts[prompt.id] === prompt else { return }
            self.prompts[prompt.id] = nil
            if let answer { record(answer, prompt.notebook) }
            for waiter in prompt.waiters { waiter.done(answer) }
        }
    }

    /// A notebook was renamed or moved: its prompts now ask for the new path.
    /// When one is already up for the new path and the same capability,
    /// the moved prompt's calls join it and the moved prompt closes.
    func move(from old: String, to new: String, prompter: LedgerPrompter?) {
        for prompt in prompts.values where prompt.notebook == old {
            if let existing = prompts.values.first(where: { $0 !== prompt && $0.notebook == new && $0.capability == prompt.capability }) {
                existing.waiters += prompt.waiters
                prompts[prompt.id] = nil
                prompter?.dismissPermission(prompt.id)
            } else {
                prompt.notebook = new
            }
        }
    }

    /// Call `call` was cancelled: it stops waiting, and a prompt nobody
    /// waits on any more is dismissed.
    func cancel(_ call: Int, prompter: LedgerPrompter?) {
        for prompt in prompts.values where prompt.waiters.contains(where: { $0.call == call }) {
            prompt.waiters.removeAll { $0.call == call }
            if prompt.waiters.isEmpty {
                prompts[prompt.id] = nil
                prompter?.dismissPermission(prompt.id)
            }
        }
    }
}
