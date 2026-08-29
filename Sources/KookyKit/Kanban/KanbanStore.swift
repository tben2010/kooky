import Foundation

/// Storage seam for the board. `FileKanbanPersistence` is production;
/// tests inject an in-memory one so they never touch `board.json`.
@MainActor
protocol KanbanPersistence {
    func load() -> [KanbanCard]?
    func save(_ cards: [KanbanCard])
}

/// `board.json` beside `state.json`. A separate file on purpose: the
/// board is app-wide while `state.json` is sliced per window, and keeping
/// the card schema out of `PersistedApp` means upstream changes to the
/// window state never collide with the fork's board format.
@MainActor
struct FileKanbanPersistence: KanbanPersistence {
    static var defaultFileURL: URL {
        AppPersistence.defaultFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("board.json")
    }

    /// Versioned envelope so a future shape change can branch on `version`
    /// the way `AppPersistence.loadFromDisk` tries new-then-legacy.
    private struct Envelope: Codable {
        static let currentVersion = 1
        var version: Int
        var cards: [KanbanCard]
    }

    let fileURL: URL

    init(fileURL: URL = FileKanbanPersistence.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() -> [KanbanCard]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Envelope.self, from: data))?.cards
    }

    func save(_ cards: [KanbanCard]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Envelope(version: Envelope.currentVersion, cards: cards)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// App-level (cross-window) card store. `@Observable` so every window's
/// board invalidates on a change made in another; a singleton for the same
/// reason `NotificationInbox` is. Column moves go through `move(_:to:)`
/// which is the one place the board's rules live — views never set
/// `card.column` directly.
@MainActor
@Observable
final class KanbanStore {
    static let shared = KanbanStore(persistence: FileKanbanPersistence())

    /// Outcome of a requested column move — the board turns `.rejected`
    /// into a shake + tooltip and `.needsLaunch` into the worktree/agent
    /// launch (which then confirms with `markLaunched`).
    enum MoveOutcome: Equatable {
        case moved
        case rejected(reasons: [String])
        /// Card is valid and now sits in In Progress awaiting the launch.
        case needsLaunch
    }

    private(set) var cards: [KanbanCard] = []
    /// Cross-window "jump to this tab" — the board can't front another
    /// window itself, so `AppDelegate` installs its `revealTab` here at
    /// launch. Default no-op keeps tests and previews self-contained.
    @ObservationIgnored var revealSession: @MainActor (UUID) -> Void = { _ in }
    private let persistence: any KanbanPersistence
    private var pendingSave: Task<Void, Never>?
    /// Same 1s debounce as `WorkspaceStore` — typing in the editor must
    /// not hit disk per keystroke.
    private static let saveDebounce: UInt64 = 1_000_000_000

    /// `internal` so tests build isolated instances. Production uses `.shared`.
    init(persistence: any KanbanPersistence) {
        self.persistence = persistence
        cards = persistence.load() ?? []
    }

    // MARK: Queries

    func card(id: UUID) -> KanbanCard? {
        cards.first { $0.id == id }
    }

    func cards(in column: KanbanColumn, project: URL? = nil) -> [KanbanCard] {
        let key = project?.standardizedFileURL.path
        return cards.filter { card in
            card.column == column && (key == nil || card.projectRoot.path == key)
        }
    }

    /// Distinct project roots across every card, for the board's filter.
    var projectRoots: [URL] {
        var seen: Set<String> = []
        return cards.compactMap { card in
            seen.insert(card.projectRoot.path).inserted ? card.projectRoot : nil
        }
    }

    /// The card that launched `sessionId`, if any — the alert path uses
    /// this to react to the agent finishing.
    func card(launchedSession sessionId: UUID) -> KanbanCard? {
        cards.first { $0.launchedSessionId == sessionId }
    }

    // MARK: Mutation

    func add(_ card: KanbanCard) {
        var card = card
        card.record("created")
        cards.append(card)
        scheduleSave()
    }

    /// Replace a card's editable fields. The column is NOT taken from the
    /// argument — `move` owns that — so an editor holding a stale copy can't
    /// silently undo a drag that happened while it was open.
    func update(_ edited: KanbanCard) {
        guard let idx = cards.firstIndex(where: { $0.id == edited.id }) else { return }
        var card = cards[idx]
        card.title = edited.title
        card.requirement = edited.requirement
        card.acceptanceCriteria = edited.acceptanceCriteria
        card.agentId = edited.agentId
        card.model = edited.model
        card.skill = edited.skill
        card.branchName = edited.branchName
        card.projectRoot = edited.projectRoot.standardizedFileURL
        card.touch()
        cards[idx] = card
        scheduleSave()
    }

    func remove(id: UUID) {
        cards.removeAll { $0.id == id }
        scheduleSave()
    }

    /// The board's rules, in one place:
    /// - Backlog → anything past it requires `isReady`.
    /// - Entering In Progress from a non-running state reports `.needsLaunch`
    ///   so the caller fires the worktree + agent; the column is already
    ///   updated so the card visibly lands while git runs.
    /// - Leaving In Progress drops the tab/workspace links (the worktree pin
    ///   stays, see `KanbanCard`).
    @discardableResult
    func move(_ id: UUID, to target: KanbanColumn) -> MoveOutcome {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else {
            return .rejected(reasons: ["card not found"])
        }
        var card = cards[idx]
        let source = card.column
        guard source != target else { return .moved }
        if target != .backlog, !card.isReady {
            return .rejected(reasons: card.readinessIssues)
        }
        card.column = target
        card.record("moved \(source.rawValue) → \(target.rawValue)")
        var outcome: MoveOutcome = .moved
        if target == .inProgress, card.launchedSessionId == nil {
            outcome = .needsLaunch
        }
        if source == .inProgress, target != .inProgress {
            card.clearLaunchLinks()
        }
        cards[idx] = card
        scheduleSave()
        return outcome
    }

    /// Called by the launch coordinator once the worktree + agent tab exist.
    func markLaunched(id: UUID, worktreePath: URL, workspaceId: UUID, sessionId: UUID, branch: String) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        var card = cards[idx]
        card.worktreePath = worktreePath.standardizedFileURL
        card.launchedWorkspaceId = workspaceId
        card.launchedSessionId = sessionId
        card.branchName = branch
        card.record("launched \(card.agentId) in \(worktreePath.lastPathComponent)")
        cards[idx] = card
        scheduleSave()
    }

    /// Launch failed after the drag already placed the card in In
    /// Progress: bounce it back to Ready so the board never shows a
    /// "running" card with no agent behind it.
    func markLaunchFailed(id: UUID, message: String) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        var card = cards[idx]
        card.column = .ready
        card.clearLaunchLinks()
        card.record("launch failed: \(message)")
        cards[idx] = card
        scheduleSave()
    }

    func recordConversationId(_ conversationId: String, forSession sessionId: UUID) {
        guard let idx = cards.firstIndex(where: { $0.launchedSessionId == sessionId }),
              cards[idx].conversationId != conversationId else { return }
        cards[idx].conversationId = conversationId
        cards[idx].touch()
        scheduleSave()
    }

    /// Write pending changes now — window close / app quit must not lose
    /// the last second of edits to the debounce.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        persistence.save(cards)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounce)
            guard let self, !Task.isCancelled else { return }
            self.persistence.save(self.cards)
        }
    }
}
