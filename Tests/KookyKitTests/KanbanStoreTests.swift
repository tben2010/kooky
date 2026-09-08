import XCTest
@testable import KookyKit

/// In-memory `KanbanPersistence` — captures saves so tests can assert on
/// debounce behaviour without touching `board.json`.
@MainActor
final class InMemoryKanbanPersistence: KanbanPersistence {
    var saved: [KanbanCard]?
    var savedArchive: [KanbanCard]?
    private(set) var saveCount = 0
    private(set) var archiveSaveCount = 0
    private let initial: [KanbanCard]?
    private let initialArchive: [KanbanCard]?

    init(initial: [KanbanCard]? = nil, initialArchive: [KanbanCard]? = nil) {
        self.initial = initial
        self.initialArchive = initialArchive
    }

    func load() -> [KanbanCard]? { initial }
    func loadArchive() -> [KanbanCard]? { initialArchive }

    func save(_ cards: [KanbanCard]) {
        saved = cards
        saveCount += 1
    }

    func saveArchive(_ cards: [KanbanCard]) {
        savedArchive = cards
        archiveSaveCount += 1
    }
}

@MainActor
final class KanbanStoreTests: XCTestCase {
    private let projectA = URL(fileURLWithPath: "/tmp/kanban-a")
    private let projectB = URL(fileURLWithPath: "/tmp/kanban-b")

    private func readyCard(project: URL? = nil, title: String = "Feature") -> KanbanCard {
        KanbanCard(
            title: title,
            requirement: "Build it",
            acceptanceCriteria: ["It works"],
            projectRoot: project ?? projectA,
            agentId: "claude-code"
        )
    }

    private func makeStore(initial: [KanbanCard]? = nil, initialArchive: [KanbanCard]? = nil) -> (KanbanStore, InMemoryKanbanPersistence) {
        let persistence = InMemoryKanbanPersistence(initial: initial, initialArchive: initialArchive)
        return (KanbanStore(persistence: persistence), persistence)
    }

    /// A card already in Done (walked there through `move`, so the rules
    /// and history are the real ones).
    private func doneCard(project: URL? = nil, title: String = "Feature", in store: KanbanStore) -> KanbanCard {
        let card = readyCard(project: project, title: title)
        store.add(card)
        store.move(card.id, to: .done)
        return store.card(id: card.id)!
    }

    // MARK: - CRUD

    func testAddUpdateRemove() {
        let (store, _) = makeStore()
        let card = readyCard()
        store.add(card)
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(store.card(id: card.id)?.events.last?.message, "created")

        var edited = card
        edited.title = "Renamed"
        edited.attachments = ["/tmp/spec.md"]
        edited.column = .done   // must be ignored — `move` owns the column
        store.update(edited)
        XCTAssertEqual(store.card(id: card.id)?.title, "Renamed")
        XCTAssertEqual(store.card(id: card.id)?.attachments, ["/tmp/spec.md"])
        XCTAssertEqual(store.card(id: card.id)?.column, .backlog)

        store.remove(id: card.id)
        XCTAssertTrue(store.cards.isEmpty)
    }

    func testCardsFilterByColumnAndProject() {
        let (store, _) = makeStore()
        let a = readyCard(project: projectA)
        let b = readyCard(project: projectB)
        store.add(a)
        store.add(b)
        XCTAssertEqual(store.cards(in: .backlog).map(\.id), [a.id, b.id])
        XCTAssertEqual(store.cards(in: .backlog, project: projectB).map(\.id), [b.id])
        XCTAssertEqual(store.cards(in: .ready).count, 0)
        XCTAssertEqual(Set(store.projectRoots.map(\.path)), [projectA.path, projectB.path])
    }

    // MARK: - Move rules

    func testMoveOutOfBacklogRequiresReadiness() {
        let (store, _) = makeStore()
        let card = KanbanCard(title: "Half done", projectRoot: projectA, agentId: "claude-code")
        store.add(card)
        let outcome = store.move(card.id, to: .ready)
        guard case .rejected(let reasons) = outcome else {
            return XCTFail("expected rejection, got \(outcome)")
        }
        XCTAssertTrue(reasons.contains("requirement is empty"))
        XCTAssertEqual(store.card(id: card.id)?.column, .backlog)
    }

    func testMoveToReadyAndBackIsFree() {
        let (store, _) = makeStore()
        let card = readyCard()
        store.add(card)
        XCTAssertEqual(store.move(card.id, to: .ready), .moved)
        XCTAssertEqual(store.move(card.id, to: .backlog), .moved)
        XCTAssertEqual(store.move(card.id, to: .backlog), .moved, "no-op move is fine")
    }

    func testMoveToInProgressReportsNeedsLaunchUntilLaunched() {
        let (store, _) = makeStore()
        let card = readyCard()
        store.add(card)
        XCTAssertEqual(store.move(card.id, to: .inProgress), .needsLaunch)
        XCTAssertEqual(store.card(id: card.id)?.column, .inProgress, "column updates before the launch runs")

        let ws = UUID(), session = UUID()
        store.markLaunched(id: card.id, worktreePath: URL(fileURLWithPath: "/tmp/kanban-a-feature"), workspaceId: ws, sessionId: session, branch: "feature/feature")
        let launched = store.card(id: card.id)!
        XCTAssertEqual(launched.launchedWorkspaceId, ws)
        XCTAssertEqual(launched.launchedSessionId, session)
        XCTAssertEqual(launched.worktreePath?.path, "/tmp/kanban-a-feature")
        XCTAssertEqual(store.card(launchedSession: session)?.id, card.id)

        // Already running: a second In Progress move (e.g. Review → back) is
        // a plain move — no second launch.
        XCTAssertEqual(store.move(card.id, to: .inReview), .moved)
        XCTAssertNil(store.card(id: card.id)?.launchedSessionId, "leaving In Progress drops the tab link")
        XCTAssertEqual(store.card(id: card.id)?.worktreePath?.path, "/tmp/kanban-a-feature", "but keeps the worktree pin")
        XCTAssertEqual(store.move(card.id, to: .inProgress), .needsLaunch, "relaunch adopts the pinned worktree")
    }

    func testMarkLaunchFailedBouncesBackToReady() {
        let (store, _) = makeStore()
        let card = readyCard()
        store.add(card)
        _ = store.move(card.id, to: .inProgress)
        store.markLaunchFailed(id: card.id, message: "fatal: branch exists")
        let bounced = store.card(id: card.id)!
        XCTAssertEqual(bounced.column, .ready)
        XCTAssertNil(bounced.launchedSessionId)
        XCTAssertTrue(bounced.events.last?.message.contains("branch exists") ?? false)
    }

    func testRecordConversationIdOnlyForLaunchedSession() {
        let (store, _) = makeStore()
        let card = readyCard()
        store.add(card)
        let session = UUID()
        store.recordConversationId("abc", forSession: session)
        XCTAssertNil(store.card(id: card.id)?.conversationId)
        store.markLaunched(id: card.id, worktreePath: projectA, workspaceId: UUID(), sessionId: session, branch: "b")
        store.recordConversationId("abc", forSession: session)
        XCTAssertEqual(store.card(id: card.id)?.conversationId, "abc")
    }

    // MARK: - Persistence

    func testLoadsInitialCardsAndFlushWritesThem() {
        let seed = readyCard()
        let (store, persistence) = makeStore(initial: [seed])
        XCTAssertEqual(store.cards.map(\.id), [seed.id])
        store.add(readyCard(title: "Second"))
        XCTAssertEqual(persistence.saveCount, 0, "save is debounced")
        store.flush()
        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertEqual(persistence.saved?.count, 2)
    }

    func testDebouncedSaveLandsAfterDelay() async throws {
        let (store, persistence) = makeStore()
        store.add(readyCard())
        store.add(readyCard(title: "Two"))
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(persistence.saveCount, 1, "two quick edits coalesce into one write")
        XCTAssertEqual(persistence.saved?.count, 2)
    }

    func testFilePersistenceRoundTripsAndToleratesMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-board-test-\(UUID().uuidString).json")
        let file = FileKanbanPersistence(fileURL: url)
        XCTAssertNil(file.load(), "missing file → nil, not an empty board")

        var card = readyCard()
        card.worktreePath = URL(fileURLWithPath: "/tmp/kanban-a-feature")
        card.launchedSessionId = UUID()
        card.model = "opus"
        card.skill = "develop"
        card.record("launched")
        file.save([card])

        let loaded = file.load()
        XCTAssertEqual(loaded?.count, 1)
        let back = loaded![0]
        XCTAssertEqual(back.id, card.id)
        XCTAssertEqual(back.title, card.title)
        XCTAssertEqual(back.acceptanceCriteria, card.acceptanceCriteria)
        XCTAssertEqual(back.column, card.column)
        XCTAssertEqual(back.projectRoot, card.projectRoot)
        XCTAssertEqual(back.worktreePath, card.worktreePath)
        XCTAssertEqual(back.launchedSessionId, card.launchedSessionId)
        XCTAssertEqual(back.model, "opus")
        XCTAssertEqual(back.skill, "develop")
        XCTAssertEqual(back.events.map(\.message), card.events.map(\.message))
        try? FileManager.default.removeItem(at: url)
    }

    func testFilePersistenceIgnoresCorruptFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-board-test-\(UUID().uuidString).json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(FileKanbanPersistence(fileURL: url).load())
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Archive

    func testArchiveMovesDoneCardOutOfCardsIntoArchivedWithHistory() {
        let (store, _) = makeStore()
        let card = doneCard(in: store)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(store.archive(id: card.id, now: now))
        XCTAssertNil(store.card(id: card.id), "archived cards leave `cards`")
        XCTAssertTrue(store.cards(in: .done).isEmpty)
        XCTAssertTrue(store.projectRoots.isEmpty, "the filter forgets a repo whose only card is archived")
        XCTAssertEqual(store.projectRoots(includingArchived: true).map(\.path), [projectA.path])

        let archived = store.archivedCard(id: card.id)
        XCTAssertNotNil(archived)
        XCTAssertEqual(archived?.column, .done)
        XCTAssertEqual(archived?.events.last?.message, "archived")
        XCTAssertEqual(archived?.events.last?.timestamp, now)
        XCTAssertEqual(archived?.events.map(\.message).dropLast(), card.events.map(\.message)[...], "history travels with the card")
        XCTAssertEqual(store.archivedCards().map(\.id), [card.id])
    }

    func testArchiveRefusesCardsOutsideDone() {
        let (store, _) = makeStore()
        let card = readyCard()
        store.add(card)
        XCTAssertFalse(store.archive(id: card.id))
        store.move(card.id, to: .inReview)
        XCTAssertFalse(store.archive(id: card.id))
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertTrue(store.archived.isEmpty)
        XCTAssertFalse(store.archive(id: UUID()), "unknown id")
    }

    func testArchiveKeepsWorktreeAndBranch() {
        let (store, _) = makeStore()
        let card = readyCard()
        store.add(card)
        store.move(card.id, to: .inProgress)
        store.markLaunched(id: card.id, worktreePath: URL(fileURLWithPath: "/tmp/kanban-a-feature"), workspaceId: UUID(), sessionId: UUID(), branch: "feature/x")
        store.move(card.id, to: .done)
        XCTAssertTrue(store.archive(id: card.id))
        let archived = store.archivedCard(id: card.id)
        XCTAssertEqual(archived?.worktreePath?.path, "/tmp/kanban-a-feature")
        XCTAssertEqual(archived?.branchName, "feature/x")
    }

    func testUnarchivePutsCardBackInDone() {
        let (store, _) = makeStore()
        let card = doneCard(in: store)
        store.archive(id: card.id)

        XCTAssertTrue(store.unarchive(id: card.id))
        XCTAssertNil(store.archivedCard(id: card.id))
        let restored = store.card(id: card.id)
        XCTAssertEqual(restored?.column, .done)
        XCTAssertEqual(restored?.events.suffix(2).map(\.message), ["archived", "unarchived"])
        XCTAssertEqual(store.cards(in: .done).map(\.id), [card.id])
        XCTAssertFalse(store.unarchive(id: card.id), "already live")
    }

    func testUnarchiveForcesDoneEvenIfArchiveSaysOtherwise() {
        var stale = readyCard()
        stale.column = .inProgress   // a hand-edited archive.json
        let (store, _) = makeStore(initialArchive: [stale])
        XCTAssertTrue(store.unarchive(id: stale.id))
        XCTAssertEqual(store.card(id: stale.id)?.column, .done)
    }

    func testArchiveAllDoneHonoursProjectFilter() {
        let (store, _) = makeStore()
        let a1 = doneCard(project: projectA, title: "A1", in: store)
        let a2 = doneCard(project: projectA, title: "A2", in: store)
        let b = doneCard(project: projectB, title: "B", in: store)
        let ready = readyCard(project: projectA, title: "not done")
        store.add(ready)

        XCTAssertEqual(store.archiveAllDone(project: projectA), 2)
        XCTAssertEqual(Set(store.archived.map(\.id)), [a1.id, a2.id])
        XCTAssertEqual(store.cards(in: .done).map(\.id), [b.id], "the other project's Done card stays")
        XCTAssertNotNil(store.card(id: ready.id), "only Done cards move")

        XCTAssertEqual(store.archiveAllDone(project: nil), 1, "nil = every project")
        XCTAssertTrue(store.cards(in: .done).isEmpty)
        XCTAssertEqual(store.archiveAllDone(project: nil), 0)
    }

    func testAutoArchiveMovesStaleDoneCardsOnly() {
        let (store, _) = makeStore()
        let day: TimeInterval = 86_400
        let now = Date()
        let old = doneCard(title: "old", in: store)
        let fresh = doneCard(title: "fresh", in: store)
        let oldReady = readyCard(title: "old but not done")
        store.add(oldReady)
        // Backdate the last history entry — that's what the sweep reads.
        var cards = store.cards
        for idx in cards.indices where cards[idx].id != fresh.id {
            cards[idx].events[cards[idx].events.count - 1].timestamp = now.addingTimeInterval(-40 * day)
        }
        let (aged, _) = makeStore(initial: cards)

        XCTAssertEqual(aged.autoArchive(doneOlderThan: 30, now: now), 1)
        XCTAssertNotNil(aged.archivedCard(id: old.id))
        XCTAssertNotNil(aged.card(id: fresh.id), "a Done card younger than N days stays")
        XCTAssertNotNil(aged.card(id: oldReady.id), "an old card outside Done stays")
        XCTAssertEqual(aged.autoArchive(doneOlderThan: 0, now: now), 0, "0 days = off, never 'everything'")
    }

    func testArchivePersistsToArchiveFileAndBoardFile() {
        let (store, persistence) = makeStore()
        let card = doneCard(in: store)
        store.archive(id: card.id)
        store.flush()
        XCTAssertEqual(persistence.saved?.count, 0, "board.json no longer holds the card")
        XCTAssertEqual(persistence.savedArchive?.map(\.id), [card.id])
        XCTAssertEqual(persistence.archiveSaveCount, 1)

        // An unrelated edit must not rewrite the archive.
        let other = readyCard(title: "other")
        store.add(other)
        store.flush()
        XCTAssertEqual(persistence.archiveSaveCount, 1)

        store.unarchive(id: card.id)
        store.flush()
        XCTAssertEqual(persistence.savedArchive?.count, 0)
        XCTAssertEqual(persistence.archiveSaveCount, 2)
        XCTAssertEqual(Set(persistence.saved?.map(\.id) ?? []), [card.id, other.id])
    }

    func testArchiveSaveIsDebouncedWithBoardSave() async throws {
        let (store, persistence) = makeStore()
        let card = doneCard(in: store)
        store.archive(id: card.id)
        XCTAssertNil(persistence.savedArchive)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(persistence.savedArchive?.map(\.id), [card.id])
    }

    func testMissingArchiveLoadsAsEmptyAndArchiveRoundTripsOnDisk() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-board-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = FileKanbanPersistence(fileURL: dir.appendingPathComponent("board.json"))
        XCTAssertEqual(file.archiveFileURL.lastPathComponent, "archive.json")
        XCTAssertEqual(file.archiveFileURL.deletingLastPathComponent().path, dir.path, "beside board.json")
        XCTAssertNil(file.loadArchive(), "no archive.json yet")

        let store = KanbanStore(persistence: file)
        XCTAssertTrue(store.archived.isEmpty, "missing archive.json → empty archive, not a failure")
        let card = doneCard(in: store)
        store.archive(id: card.id)
        store.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.archiveFileURL.path))
        let raw = try? JSONSerialization.jsonObject(with: Data(contentsOf: file.archiveFileURL)) as? [String: Any]
        XCTAssertEqual(raw?["version"] as? Int, 1, "same versioned envelope as board.json")
        XCTAssertEqual((raw?["cards"] as? [Any])?.count, 1)

        let reloaded = KanbanStore(persistence: file)
        XCTAssertTrue(reloaded.cards.isEmpty)
        XCTAssertEqual(reloaded.archivedCard(id: card.id)?.title, card.title)
        XCTAssertEqual(reloaded.archivedCard(id: card.id)?.events.last?.message, "archived")
    }

    func testCorruptArchiveDoesNotTakeTheBoardDown() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-board-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = FileKanbanPersistence(fileURL: dir.appendingPathComponent("board.json"))
        file.save([readyCard()])
        try "not json".write(to: file.archiveFileURL, atomically: true, encoding: .utf8)
        let store = KanbanStore(persistence: file)
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertTrue(store.archived.isEmpty)
    }
}
