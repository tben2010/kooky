import XCTest
@testable import KookyKit

/// In-memory `KanbanPersistence` — captures saves so tests can assert on
/// debounce behaviour without touching `board.json`.
@MainActor
final class InMemoryKanbanPersistence: KanbanPersistence {
    var saved: [KanbanCard]?
    private(set) var saveCount = 0
    private let initial: [KanbanCard]?

    init(initial: [KanbanCard]? = nil) {
        self.initial = initial
    }

    func load() -> [KanbanCard]? { initial }

    func save(_ cards: [KanbanCard]) {
        saved = cards
        saveCount += 1
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

    private func makeStore(initial: [KanbanCard]? = nil) -> (KanbanStore, InMemoryKanbanPersistence) {
        let persistence = InMemoryKanbanPersistence(initial: initial)
        return (KanbanStore(persistence: persistence), persistence)
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
        edited.column = .done   // must be ignored — `move` owns the column
        store.update(edited)
        XCTAssertEqual(store.card(id: card.id)?.title, "Renamed")
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
}
