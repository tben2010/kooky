import Foundation
import os

/// Storage seam for the board. `FileKanbanPersistence` is production;
/// tests inject an in-memory one so they never touch `board.json`.
@MainActor
protocol KanbanPersistence {
    func load() -> [KanbanCard]?
    func save(_ cards: [KanbanCard])
    /// Archived (Done, then archived) cards — `archive.json`. nil when no
    /// archive has been written yet; the store treats that as empty.
    func loadArchive() -> [KanbanCard]?
    func saveArchive(_ cards: [KanbanCard])
}

/// `board.json` beside `state.json`. A separate file on purpose: the
/// board is app-wide while `state.json` is sliced per window, and keeping
/// the card schema out of `PersistedApp` means upstream changes to the
/// window state never collide with the fork's board format.
///
/// Archived cards live in `archive.json` next to it — same envelope, its
/// own file, so the board file stays small however long the archive
/// grows and a corrupt archive never takes the live board down with it.
@MainActor
struct FileKanbanPersistence: KanbanPersistence {
    static var defaultFileURL: URL {
        AppPersistence.dataDirectory.appending(path: "board.json")
    }

    static var defaultArchiveFileURL: URL {
        AppPersistence.dataDirectory.appending(path: "archive.json")
    }

    /// Versioned envelope so a future shape change can branch on `version`
    /// the way `AppPersistence.loadFromDisk` tries new-then-legacy. A file
    /// from a newer build is treated like an unreadable one: set aside,
    /// never overwritten by this build's smaller understanding of it.
    private struct Envelope: Codable {
        static let currentVersion = 1
        var version: Int
        var cards: [KanbanCard]
    }

    private static let logger = Logger(subsystem: "kooky", category: "kanban-persistence")

    let fileURL: URL
    let archiveFileURL: URL

    /// `archiveFileURL` defaults to `archive.json` beside `fileURL`, so a
    /// test pointing the board at a temp directory gets its archive there
    /// too.
    init(fileURL: URL = FileKanbanPersistence.defaultFileURL, archiveFileURL: URL? = nil) {
        self.fileURL = fileURL
        self.archiveFileURL = archiveFileURL
            ?? fileURL.deletingLastPathComponent().appending(path: "archive.json")
    }

    func load() -> [KanbanCard]? { read(from: fileURL) }
    func save(_ cards: [KanbanCard]) { write(cards, to: fileURL) }
    func loadArchive() -> [KanbanCard]? { read(from: archiveFileURL) }
    func saveArchive(_ cards: [KanbanCard]) { write(cards, to: archiveFileURL) }

    /// Where an unreadable file ends up: `board.json` →
    /// `board.unreadable-20260908T101500.json` beside it. The store then
    /// starts empty, and the next save writes a fresh file without
    /// destroying whatever the old one held.
    static func quarantineURL(for url: URL, now: Date = .now) -> URL {
        let stamp = now.formatted(.iso8601.year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appending(path: "\(name).unreadable-\(stamp).json")
    }

    /// nil = no file yet, or one this build can't read. The unreadable
    /// case is logged and the file moved aside (see `quarantineURL`); it
    /// is never silently treated as "empty board, fine to overwrite".
    private func read(from url: URL) -> [KanbanCard]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.version <= Envelope.currentVersion else {
                setAside(url, reason: "written by a newer build (version \(envelope.version))")
                return nil
            }
            return envelope.cards
        } catch {
            setAside(url, reason: String(describing: error))
            return nil
        }
    }

    private func setAside(_ url: URL, reason: String) {
        let target = Self.quarantineURL(for: url)
        do {
            try FileManager.default.moveItem(at: url, to: target)
            Self.logger.error("\(url.lastPathComponent, privacy: .public) is unreadable (\(reason, privacy: .public)); moved to \(target.lastPathComponent, privacy: .public)")
        } catch {
            Self.logger.error("\(url.lastPathComponent, privacy: .public) is unreadable (\(reason, privacy: .public)) and could not be moved aside: \(String(describing: error), privacy: .public)")
        }
    }

    private func write(_ cards: [KanbanCard], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(Envelope(version: Envelope.currentVersion, cards: cards))
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("saving \(url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
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
    /// Cards taken off the board from Done. Not in `cards` — every board
    /// query, project filter and launch path sees only live cards; the
    /// archive is read through `archivedCard(id:)` / `archivedCards(project:)`.
    /// Oldest first (append order); the board shows it newest first.
    private(set) var archived: [KanbanCard] = []
    /// Cross-window "jump to this tab" — the board can't front another
    /// window itself, so `AppDelegate` installs its `revealTab` here at
    /// launch. Default no-op keeps tests and previews self-contained.
    @ObservationIgnored var revealSession: @MainActor (UUID) -> Void = { _ in }
    private let persistence: any KanbanPersistence
    private var pendingSave: Task<Void, Never>?
    /// The archive changes rarely; it's only rewritten when it did.
    private var archiveDirty = false
    private var autoArchiveTask: Task<Void, Never>?
    /// Same 1s debounce as `WorkspaceStore` — typing in the editor must
    /// not hit disk per keystroke.
    private static let saveDebounce: Duration = .seconds(1)

    /// `internal` so tests build isolated instances. Production uses `.shared`.
    init(persistence: any KanbanPersistence) {
        self.persistence = persistence
        cards = persistence.load() ?? []
        archived = persistence.loadArchive() ?? []
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

    /// Distinct project roots across every live card, for the board's
    /// filter. Archived cards don't count — a repo whose every card is
    /// archived leaves the picker until the archive is shown.
    var projectRoots: [URL] {
        projectRoots(includingArchived: false)
    }

    func projectRoots(includingArchived: Bool) -> [URL] {
        var seen: Set<String> = []
        return (includingArchived ? cards + archived : cards).compactMap { card in
            seen.insert(card.projectRoot.path).inserted ? card.projectRoot : nil
        }
    }

    // MARK: Archive

    func archivedCard(id: UUID) -> KanbanCard? {
        archived.first { $0.id == id }
    }

    /// Archived cards of one project (nil = every project), oldest first.
    func archivedCards(project: URL? = nil) -> [KanbanCard] {
        let key = project?.standardizedFileURL.path
        return archived.filter { key == nil || $0.projectRoot.path == key }
    }

    /// Take a Done card off the board into the archive. Only Done cards
    /// qualify — archiving is "this is finished and I'm done looking at
    /// it", not a way to hide unfinished work. Nothing else changes: the
    /// worktree pin, branch and history travel with the card so a restore
    /// puts back exactly what left.
    @discardableResult
    func archive(id: UUID, now: Date = Date.now) -> Bool {
        guard let idx = cards.firstIndex(where: { $0.id == id }), cards[idx].column == .done else { return false }
        var card = cards.remove(at: idx)
        card.record("archived", now: now)
        archived.append(card)
        scheduleSave(archive: true)
        return true
    }

    /// Back to Done. The column is forced to Done regardless of what the
    /// archived copy says — the archive only ever holds Done cards, and a
    /// restore must never resurrect a card into In Progress.
    @discardableResult
    func unarchive(id: UUID, now: Date = Date.now) -> Bool {
        guard let idx = archived.firstIndex(where: { $0.id == id }) else { return false }
        var card = archived.remove(at: idx)
        card.column = .done
        card.record("unarchived", now: now)
        cards.append(card)
        scheduleSave(archive: true)
        return true
    }

    /// Archive every Done card of `project` (nil = all projects). Returns
    /// how many moved.
    @discardableResult
    func archiveAllDone(project: URL?, now: Date = Date.now) -> Int {
        let ids = cards(in: .done, project: project).map(\.id)
        for id in ids { archive(id: id, now: now) }
        return ids.count
    }

    /// The "archive Done cards after N days" sweep: a Done card whose last
    /// history entry is older than `days` goes to the archive. The last
    /// event, not `updatedAt`, so a note added yesterday keeps the card
    /// on the board. Returns how many moved.
    @discardableResult
    func autoArchive(doneOlderThan days: Int, now: Date = Date.now) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        let stale = cards.filter { card in
            card.column == .done && (card.events.last?.timestamp ?? card.updatedAt) < cutoff
        }
        for card in stale { archive(id: card.id, now: now) }
        return stale.count
    }

    /// Run the auto-archive sweep now and once a day from then on. `days`
    /// is read on every tick (nil = the setting is off), so a change in
    /// Settings applies at the next tick without a restart.
    static let autoArchiveInterval: Duration = .seconds(24 * 3_600)
    func startAutoArchive(days: @escaping @MainActor () -> Int?) {
        autoArchiveTask?.cancel()
        autoArchiveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let days = days() { self.autoArchive(doneOlderThan: days) }
                try? await Task.sleep(for: Self.autoArchiveInterval)
            }
        }
    }

    /// The card that launched `sessionId`, if any — the alert path uses
    /// this to react to the agent finishing.
    func card(launchedSession sessionId: UUID) -> KanbanCard? {
        cards.first { $0.launchedSessionId == sessionId }
    }

    /// Like `card(launchedSession:)` but survives the card leaving In
    /// Progress — for alerts that trail the agent's exit.
    func card(everLaunchedSession sessionId: UUID) -> KanbanCard? {
        cards.first { $0.lastLaunchedSessionId == sessionId }
    }

    /// Seconds since the card's last `launched …` event; nil if never.
    func secondsSinceLaunch(id: UUID, now: Date = Date.now) -> TimeInterval? {
        guard let card = card(id: id),
              let launched = card.events.last(where: { $0.message.hasPrefix("launched") }) else { return nil }
        return now.timeIntervalSince(launched.timestamp)
    }

    /// The agent tab reported it's done (`.completed`). A real run moves
    /// to In Review; an exit within seconds of the launch is a failed start
    /// (bad resume id, missing binary, refused prompt) and bounces to Ready
    /// so the board never shows "review this" for work that never began.
    static let quickExitWindow: TimeInterval = 15
    @discardableResult
    func agentFinished(sessionId: UUID, now: Date = Date.now) -> KanbanColumn? {
        guard let card = card(launchedSession: sessionId), card.column == .inProgress else { return nil }
        if let elapsed = secondsSinceLaunch(id: card.id, now: now), elapsed < Self.quickExitWindow {
            markLaunchFailed(id: card.id, message: "agent exited \(Int(elapsed))s after start")
            return .ready
        }
        move(card.id, to: .inReview)
        return .inReview
    }

    /// The agent process exited non-zero. Whether the card is still In
    /// Progress or was just auto-moved to In Review by the trailing
    /// `completed`, that isn't a finished feature: back to Ready with the
    /// status on record.
    func agentFailed(sessionId: UUID, exitCode: Int, now: Date = Date.now) {
        guard let card = card(everLaunchedSession: sessionId),
              let idx = cards.firstIndex(where: { $0.id == card.id }) else { return }
        // Still the running launch, or the auto-move to In Review that the
        // trailing exit marker follows by a moment. A reopened conversation
        // the user quit later must not bounce the card.
        let justReviewed = card.column == .inReview
            && card.events.last?.message == "moved inProgress → inReview"
            && now.timeIntervalSince(card.events.last?.timestamp ?? .distantPast) < 10
        guard card.launchedSessionId == sessionId || justReviewed else { return }
        var updated = cards[idx]
        updated.column = .ready
        updated.clearLaunchLinks()
        updated.record("agent exited with status \(exitCode) — back to Ready")
        cards[idx] = updated
        scheduleSave()
    }

    /// A conversation reopened from the card (its original tab is gone):
    /// remember the new tab for the badge / watch / reveal, WITHOUT making
    /// it a launch — the column stays, and the exit handling that turns a
    /// launch's early death into "back to Ready" must not fire for a tab the
    /// user merely opened to look.
    func linkReopenedSession(id: UUID, sessionId: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[idx].lastLaunchedSessionId = sessionId
        cards[idx].record("conversation reopened")
        scheduleSave()
    }

    /// A stored conversation id turned out not to exist on disk — forget
    /// it so the next launch starts fresh instead of failing the resume.
    func dropConversationId(id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }), cards[idx].conversationId != nil else { return }
        cards[idx].conversationId = nil
        cards[idx].record("stale conversation id dropped — next launch starts fresh")
        scheduleSave()
    }

    // MARK: Mutation

    func add(_ card: KanbanCard) {
        var card = card
        card.record("created")
        cards.append(card)
        KanbanAttachmentStore.removeOrphans(cardId: card.id, keeping: card.attachments)
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
        card.attachments = edited.attachments
        card.branchName = edited.branchName
        card.projectRoot = edited.projectRoot.standardizedFileURL
        card.touch()
        cards[idx] = card
        // Pasted screenshots the editor dropped again are Kooky's files —
        // delete them with the reference.
        KanbanAttachmentStore.removeOrphans(cardId: card.id, keeping: card.attachments)
        scheduleSave()
    }

    func remove(id: UUID) {
        cards.removeAll { $0.id == id }
        KanbanAttachmentStore.removeAll(cardId: id)
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

    /// Called by the launch coordinator once the agent tab exists.
    /// `worktreePath` nil = the agent works in the repo itself (card on the
    /// main checkout's branch); the card then carries no worktree pin.
    func markLaunched(id: UUID, worktreePath: URL?, workspaceId: UUID, sessionId: UUID, branch: String) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        var card = cards[idx]
        card.worktreePath = worktreePath?.standardizedFileURL
        card.launchedWorkspaceId = workspaceId
        card.launchedSessionId = sessionId
        card.lastLaunchedSessionId = sessionId
        card.branchName = branch
        let place = worktreePath.map { "worktree \($0.lastPathComponent)" } ?? "repo on \(branch)"
        card.record("launched \(card.agentId) in \(place)")
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

    /// Agent-written note (`kooky-cli card --note`). Lands in the event
    /// log with a `note: ` prefix so `card --show` can list notes apart
    /// from column moves.
    func appendNote(id: UUID, text: String) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[idx].record("note: \(singleLine(text))")
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
        if archiveDirty {
            persistence.saveArchive(archived)
            archiveDirty = false
        }
    }

    private func scheduleSave(archive: Bool = false) {
        if archive { archiveDirty = true }
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard let self, !Task.isCancelled else { return }
            self.persistence.save(self.cards)
            if self.archiveDirty {
                self.persistence.saveArchive(self.archived)
                self.archiveDirty = false
            }
        }
    }
}
