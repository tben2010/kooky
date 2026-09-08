import XCTest
@testable import KookyKit
import KookyHookKit

/// Phase 2 seams: `card` CLI verb against the controller, model flags on
/// templates, resume-on-relaunch, and the skill catalog scan.
@MainActor
final class KanbanPhase2Tests: XCTestCase {
    private let projectA = URL(fileURLWithPath: "/tmp/projectA")

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(atPath: "/tmp/projectA", withIntermediateDirectories: true)
    }

    // MARK: - Fixtures

    private func makeController(
        store: WorkspaceStore,
        board: KanbanStore,
        isShuttingDown: @escaping @MainActor () -> Bool = { false }
    ) -> KookyCLIController {
        let context = KookyCLIController.WindowContext(
            store: store,
            isKey: true,
            reveal: { _, _ in },
            window: { nil }
        )
        return KookyCLIController(
            appVersion: "test",
            windows: { [context] },
            fallbackWindow: { (context, false) },
            activateApp: {},
            isShuttingDown: isShuttingDown,
            templates: { AgentTemplate.builtin },
            board: { board },
            resume: { _, _, _, _, completion in completion(.opened) }
        )
    }

    private func respond(_ controller: KookyCLIController, _ request: KookyCLIRequest) async -> KookyCLIResponse {
        await withCheckedContinuation { continuation in
            controller.handle(request) { continuation.resume(returning: $0) }
        }
    }

    private func launchedCard(store: WorkspaceStore, board: KanbanStore) -> (KanbanCard, Session) {
        let card = KanbanCard(
            title: "Card",
            requirement: "Req",
            acceptanceCriteria: ["AC"],
            projectRoot: projectA,
            agentId: AgentTemplate.claudeCodeID
        )
        board.add(card)
        _ = board.move(card.id, to: .inProgress)
        let ws = store.workspaces[0]
        let session = store.addTab(in: ws, template: .claudeCode)
        board.markLaunched(id: card.id, worktreePath: projectA, workspaceId: ws.id, sessionId: session.id, branch: "feature/card")
        return (board.card(id: card.id)!, session)
    }

    // MARK: - card verb

    func testCardDoneByIdMovesToInReview() async {
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let (card, _) = launchedCard(store: store, board: board)
        let controller = makeController(store: store, board: board)
        let response = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "done", cardId: card.id.uuidString))
        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(board.card(id: card.id)?.column, .inReview)
        XCTAssertNil(board.card(id: card.id)?.launchedSessionId, "leaving In Progress drops the tab link")
    }

    func testCardDoneResolvesCardFromSurfaceAndCapturesConversation() async {
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let (card, session) = launchedCard(store: store, board: board)
        session.conversationId = "conv-123"
        let controller = makeController(store: store, board: board)
        let response = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "done", surface: session.id.uuidString))
        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(board.card(id: card.id)?.column, .inReview)
        XCTAssertEqual(board.card(id: card.id)?.conversationId, "conv-123")
    }

    func testCardDoneOutsideInProgressIsANoOp() async {
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let card = KanbanCard(title: "T", requirement: "R", acceptanceCriteria: ["A"], projectRoot: projectA, agentId: "claude-code")
        board.add(card)
        let controller = makeController(store: store, board: board)
        let response = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "done", cardId: card.id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(board.card(id: card.id)?.column, .backlog)
        XCTAssertTrue(response.note?.contains("nothing moved") ?? false)
    }

    func testCardNoteAppendsAndShowRendersIt() async {
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let (card, _) = launchedCard(store: store, board: board)
        let controller = makeController(store: store, board: board)
        let noted = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "note", cardId: card.id.uuidString, note: "tests\nare green"))
        XCTAssertTrue(noted.ok)
        XCTAssertEqual(board.card(id: card.id)?.events.last?.message, "note: tests are green")

        let shown = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "show", cardId: card.id.uuidString))
        XCTAssertTrue(shown.ok)
        let text = shown.note ?? ""
        XCTAssertTrue(text.contains("title: Card"), text)
        XCTAssertTrue(text.contains("column: inProgress"), text)
        XCTAssertTrue(text.contains("- [ ] AC"), text)
        XCTAssertTrue(text.contains("- tests are green"), text)
    }

    func testCardShowFindsArchivedCardsAndOtherVerbsRefuseThem() async {
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let (card, _) = launchedCard(store: store, board: board)
        board.move(card.id, to: .done)
        XCTAssertTrue(board.archive(id: card.id))
        let controller = makeController(store: store, board: board)

        let shown = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "show", cardId: card.id.uuidString))
        XCTAssertTrue(shown.ok)
        let text = shown.note ?? ""
        XCTAssertTrue(text.contains("title: Card"), text)
        XCTAssertTrue(text.contains("column: done"), text)
        XCTAssertTrue(text.contains("archived: yes"), text)

        let noted = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "note", cardId: card.id.uuidString, note: "late"))
        XCTAssertFalse(noted.ok)
        XCTAssertTrue(noted.error?.contains("archived") == true, noted.error ?? "")
        XCTAssertNil(board.archivedCard(id: card.id)?.events.last(where: { $0.message == "note: late" }))

        let done = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "done", cardId: card.id.uuidString))
        XCTAssertFalse(done.ok)
        XCTAssertNotNil(board.archivedCard(id: card.id), "still archived")
    }

    func testCardRefusalsAreReadable() async {
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let controller = makeController(store: store, board: board)
        let noId = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "done"))
        XCTAssertFalse(noId.ok)
        XCTAssertTrue(noId.error?.contains("--id") ?? false)

        let unknownSurface = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "done", surface: UUID().uuidString))
        XCTAssertFalse(unknownSurface.ok)
        XCTAssertTrue(unknownSurface.error?.contains("not launched from a Kanban card") ?? false)

        let unknownId = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "done", cardId: UUID().uuidString))
        XCTAssertFalse(unknownId.ok)

        let (card, _) = launchedCard(store: store, board: board)
        let badAction = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "explode", cardId: card.id.uuidString))
        XCTAssertFalse(badAction.ok)
        let emptyNote = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "note", cardId: card.id.uuidString, note: "  "))
        XCTAssertFalse(emptyNote.ok)
    }

    // MARK: - Model flags

    // MARK: - card --new

    /// `<tmp>/<uuid>/repo` on `main` with one commit, plus a `sub/` dir so
    /// the request can name a directory that is not the root.
    private func makeGitRepo() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-cli-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Test"],
            ["commit", "-q", "--allow-empty", "-m", "init"],
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return repo
    }

    func testCardNewCreatesBacklogCardAtRepoRootOnCurrentBranch() async throws {
        let repo = try makeGitRepo()
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let controller = makeController(store: store, board: board)
        let response = await respond(controller, KookyCLIRequest(
            verb: .card,
            cwd: repo.appendingPathComponent("sub").path,
            title: "  Palette entry  ",
            cardAction: "new",
            requirement: "Add a palette item.\n",
            criteria: "- [ ] item shows up\n\n* opens the editor\n"
        ))
        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(board.cards.count, 1)
        let card = try XCTUnwrap(board.cards.first)
        XCTAssertEqual(card.title, "Palette entry")
        XCTAssertEqual(card.requirement, "Add a palette item.")
        XCTAssertEqual(card.acceptanceCriteria, ["item shows up", "opens the editor"])
        XCTAssertEqual(card.column, .backlog)
        XCTAssertEqual(card.projectRoot.standardizedFileURL.path, repo.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(card.branchName, "main")
        XCTAssertEqual(card.agentId, AgentTemplate.claudeCodeID)
        XCTAssertEqual(card.events.map(\.message), ["created"])
        // The id is the third word so scripts can feed it to --start.
        let words = (response.note ?? "").split(separator: " ")
        XCTAssertEqual(words.count > 2 ? String(words[2]) : "", card.id.uuidString)
    }

    /// The ⌘Q drain has flushed the board by the time the off-main probe
    /// returns — a card added now lives for one second and is lost. Same
    /// gate the `open` verb applies after its own hop.
    func testCardNewRefusesAfterShutdownBeganInsteadOfCreatingALostCard() async throws {
        let repo = try makeGitRepo()
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let controller = makeController(store: store, board: board, isShuttingDown: { true })
        let response = await respond(controller, KookyCLIRequest(
            verb: .card,
            cwd: repo.path,
            title: "Late",
            cardAction: "new"
        ))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "kooky is shutting down")
        XCTAssertTrue(board.cards.isEmpty)
    }

    func testCardStartReportsShutdownInsteadOfSuccess() async throws {
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let controller = makeController(store: store, board: board, isShuttingDown: { true })
        let card = KanbanCard(title: "Late", requirement: "R", acceptanceCriteria: ["A"], projectRoot: projectA, agentId: AgentTemplate.claudeCodeID)
        board.add(card)
        _ = board.move(card.id, to: .ready)
        let response = await respond(controller, KookyCLIRequest(verb: .card, cardAction: "start", cardId: card.id.uuidString))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "kooky is shutting down")
    }

    func testCardNewHonoursExplicitAgentAndBranch() async throws {
        let repo = try makeGitRepo()
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let controller = makeController(store: store, board: board)
        let response = await respond(controller, KookyCLIRequest(
            verb: .card, cwd: repo.path, agent: "codex", title: "T", cardAction: "new", branch: "feature/palette"
        ))
        XCTAssertTrue(response.ok, response.error ?? "")
        let card = try XCTUnwrap(board.cards.first)
        XCTAssertEqual(card.agentId, "codex")
        XCTAssertEqual(card.branchName, "feature/palette")
        XCTAssertEqual(card.acceptanceCriteria, [])
        XCTAssertEqual(card.requirement, "")
    }

    func testCardNewRefusalsAreReadable() async throws {
        let repo = try makeGitRepo()
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let controller = makeController(store: store, board: board)

        let blankTitle = await respond(controller, KookyCLIRequest(verb: .card, cwd: repo.path, title: " ", cardAction: "new"))
        XCTAssertFalse(blankTitle.ok)
        XCTAssertTrue(blankTitle.error?.contains("--title") == true, blankTitle.error ?? "")

        let noCwd = await respond(controller, KookyCLIRequest(verb: .card, title: "T", cardAction: "new"))
        XCTAssertFalse(noCwd.ok)
        XCTAssertTrue(noCwd.error?.contains("--cwd") == true, noCwd.error ?? "")

        let relative = await respond(controller, KookyCLIRequest(verb: .card, cwd: "repo", title: "T", cardAction: "new"))
        XCTAssertFalse(relative.ok)
        XCTAssertTrue(relative.error?.contains("absolute") == true, relative.error ?? "")

        let outsideGit = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideGit, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outsideGit) }
        let noRepo = await respond(controller, KookyCLIRequest(verb: .card, cwd: outsideGit.path, title: "T", cardAction: "new"))
        XCTAssertFalse(noRepo.ok)
        XCTAssertTrue(noRepo.error?.contains("git repository") == true, noRepo.error ?? "")

        let missingDir = await respond(controller, KookyCLIRequest(verb: .card, cwd: "/nonexistent/\(UUID().uuidString)", title: "T", cardAction: "new"))
        XCTAssertFalse(missingDir.ok)

        let unknownAgent = await respond(controller, KookyCLIRequest(verb: .card, cwd: repo.path, agent: "nope", title: "T", cardAction: "new"))
        XCTAssertFalse(unknownAgent.ok)
        XCTAssertTrue(unknownAgent.error?.contains("known templates") == true, unknownAgent.error ?? "")

        XCTAssertTrue(board.cards.isEmpty)
    }

    func testBuiltinModelFlagsAndCustomInheritance() {
        XCTAssertEqual(AgentTemplate.claudeCode.modelFlag, "--model")
        XCTAssertEqual(AgentTemplate.codex.modelFlag, "-m")
        XCTAssertEqual(AgentTemplate.gemini.modelFlag, "-m")
        XCTAssertNil(AgentTemplate.terminal.modelFlag)
        XCTAssertNil(AgentTemplate.droid.modelFlag)
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "claude-opus", title: "Claude Opus", command: "", baseAgentId: AgentTemplate.claudeCodeID))
        XCTAssertEqual(custom.modelFlag, "--model", "customs inherit the base binary's flag")
        XCTAssertEqual(KanbanLaunchCoordinator.modelOptions(template: custom, model: "opus"), "--model opus")
        XCTAssertNil(KanbanLaunchCoordinator.modelOptions(template: .droid, model: "x"))
    }

    func testModelSuggestionsFollowRosterId() {
        XCTAssertEqual(KanbanModelSuggestions.suggestions(for: .claudeCode), ["fable", "opus", "sonnet", "haiku"])
        XCTAssertFalse(KanbanModelSuggestions.suggestions(for: .codex).isEmpty)
        XCTAssertTrue(KanbanModelSuggestions.suggestions(for: .terminal).isEmpty)
        XCTAssertTrue(KanbanModelSuggestions.suggestions(for: nil).isEmpty)
    }

    func testResolveReadsConfiguredDefaultsNearestScopeFirst() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home")
        let project = base.appendingPathComponent("project")
        func write(_ path: String, _ content: String) throws {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("home/.claude/settings.json", #"{"model": "claude-fable-5[1m]"}"#)
        try write("home/.codex/config.toml", "model = \"gpt-5-codex\" # default\n[profiles.x]\nmodel = \"other\"\n")
        try write("home/.gemini/settings.json", #"{"model": {"name": "gemini-2.5-pro"}}"#)

        let claude = KanbanModelSuggestions.resolve(for: .claudeCode, projectRoot: project, home: home)
        XCTAssertEqual(claude.defaultModel, "claude-fable-5[1m]")
        XCTAssertEqual(claude.suggestions.first, "claude-fable-5[1m]", "configured default is offered first")
        XCTAssertTrue(claude.suggestions.contains("fable"))

        // Project-level settings beat the user file.
        try write("project/.claude/settings.local.json", #"{"model": "sonnet"}"#)
        XCTAssertEqual(KanbanModelSuggestions.resolve(for: .claudeCode, projectRoot: project, home: home).defaultModel, "sonnet")

        XCTAssertEqual(KanbanModelSuggestions.resolve(for: .codex, projectRoot: nil, home: home).defaultModel, "gpt-5-codex")
        XCTAssertEqual(KanbanModelSuggestions.resolve(for: .gemini, projectRoot: nil, home: home).defaultModel, "gemini-2.5-pro")
        XCTAssertNil(KanbanModelSuggestions.resolve(for: .droid, projectRoot: nil, home: home).defaultModel)
        XCTAssertNil(KanbanModelSuggestions.resolve(for: .claudeCode, projectRoot: nil, home: base.appendingPathComponent("nowhere")).defaultModel)
    }

    // MARK: - Resume on relaunch

    func testRelaunchResumesCapturedConversation() async throws {
        let previous = KanbanLaunchCoordinator.conversationExists
        KanbanLaunchCoordinator.conversationExists = { _, id in id == "abc-123" }
        defer { KanbanLaunchCoordinator.conversationExists = previous }
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        // Pretend a first launch happened into an existing worktree dir.
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        let card = KanbanCard(title: "Resume me", requirement: "R", acceptanceCriteria: ["A"], projectRoot: projectA, agentId: AgentTemplate.claudeCodeID)
        board.add(card)
        _ = board.move(card.id, to: .inProgress)
        let ws = store.workspaces[0]
        let first = store.addTab(in: ws, template: .claudeCode)
        first.conversationId = "abc-123"
        board.markLaunched(id: card.id, worktreePath: worktree, workspaceId: ws.id, sessionId: first.id, branch: "feature/resume-me")

        // Human pulls it back: the board syncs the conversation id first.
        KanbanLaunchCoordinator.syncConversationId(card: board.card(id: card.id)!, board: board, store: store)
        XCTAssertEqual(board.move(card.id, to: .backlog), .moved)
        XCTAssertEqual(board.card(id: card.id)?.conversationId, "abc-123")

        XCTAssertEqual(board.move(card.id, to: .inProgress), .needsLaunch)
        let failure = await KanbanLaunchCoordinator.launch(cardId: card.id, board: board, store: store)
        XCTAssertNil(failure)
        let relaunched = try XCTUnwrap(board.card(id: card.id))
        let session = try XCTUnwrap(store.locateSession(relaunched.launchedSessionId!)?.session)
        let command = try XCTUnwrap((session.engine as? TestEngine)?.startedConfigs.first?.environment["KOOKY_AGENT"])
        XCTAssertEqual(command, "claude --resume abc-123", "resume, no prompt (a prompt would suppress the resume)")
    }

    func testRelaunchDropsAConversationIdTheAgentNoLongerHas() async throws {
        let previous = KanbanLaunchCoordinator.conversationExists
        KanbanLaunchCoordinator.conversationExists = { _, _ in false }
        defer { KanbanLaunchCoordinator.conversationExists = previous }
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        var card = KanbanCard(title: "Stale", requirement: "R", acceptanceCriteria: ["A"], projectRoot: projectA, agentId: AgentTemplate.claudeCodeID)
        card.worktreePath = worktree
        card.conversationId = "gone-123"
        board.add(card)
        _ = board.move(card.id, to: .inProgress)
        let failure = await KanbanLaunchCoordinator.launch(cardId: card.id, board: board, store: store)
        XCTAssertNil(failure)
        let launched = try XCTUnwrap(board.card(id: card.id))
        XCTAssertNil(launched.conversationId, "a resume id the agent can't find is dropped, not retried")
        let session = try XCTUnwrap(store.locateSession(launched.launchedSessionId!)?.session)
        let command = try XCTUnwrap((session.engine as? TestEngine)?.startedConfigs.first?.environment["KOOKY_AGENT"])
        XCTAssertFalse(command.contains("--resume"), command)
        XCTAssertTrue(command.contains("# Feature: Stale"), "fresh launch carries the prompt: \(command)")
    }

    // MARK: - Agent exit handling

    func testQuickExitBouncesToReadyAndRealExitMovesToReview() {
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let card = KanbanCard(title: "T", requirement: "R", acceptanceCriteria: ["A"], projectRoot: projectA, agentId: "claude-code")
        board.add(card)
        _ = board.move(card.id, to: .inProgress)
        let session = UUID()
        board.markLaunched(id: card.id, worktreePath: nil, workspaceId: UUID(), sessionId: session, branch: "main")
        XCTAssertEqual(board.agentFinished(sessionId: session), .ready, "an exit seconds after launch is a failed start")
        XCTAssertEqual(board.card(id: card.id)?.column, .ready)
        XCTAssertTrue(board.card(id: card.id)?.events.last?.message.contains("after start") ?? false)

        _ = board.move(card.id, to: .inProgress)
        let later = UUID()
        board.markLaunched(id: card.id, worktreePath: nil, workspaceId: UUID(), sessionId: later, branch: "main")
        let farFuture = Date().addingTimeInterval(KanbanStore.quickExitWindow + 60)
        XCTAssertEqual(board.agentFinished(sessionId: later, now: farFuture), .inReview)
        XCTAssertEqual(board.card(id: card.id)?.column, .inReview)
        XCTAssertNil(board.agentFinished(sessionId: later), "already handled — no double move")
    }

    func testNonZeroExitAfterAutoReviewBouncesBackToReady() {
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let card = KanbanCard(title: "T", requirement: "R", acceptanceCriteria: ["A"], projectRoot: projectA, agentId: "claude-code")
        board.add(card)
        _ = board.move(card.id, to: .inProgress)
        let session = UUID()
        board.markLaunched(id: card.id, worktreePath: nil, workspaceId: UUID(), sessionId: session, branch: "main")
        // `completed` lands first (moves to In Review), the shell's exit-code
        // marker trails it — the card must still be found via lastLaunchedSessionId.
        XCTAssertEqual(board.agentFinished(sessionId: session, now: Date().addingTimeInterval(120)), .inReview)
        XCTAssertNil(board.card(id: card.id)?.launchedSessionId)
        board.agentFailed(sessionId: session, exitCode: 1)
        XCTAssertEqual(board.card(id: card.id)?.column, .ready)
        XCTAssertTrue(board.card(id: card.id)?.events.last?.message.contains("status 1") ?? false)
        // A stranger's session id does nothing.
        board.agentFailed(sessionId: UUID(), exitCode: 1)
        XCTAssertEqual(board.card(id: card.id)?.column, .ready)
    }

    func testRelaunchWithoutConversationSendsPromptAgain() async throws {
        let store = makeTestStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-noresume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        var card = KanbanCard(title: "Fresh", requirement: "R", acceptanceCriteria: ["A"], projectRoot: projectA, agentId: AgentTemplate.claudeCodeID)
        card.worktreePath = worktree
        board.add(card)
        _ = board.move(card.id, to: .inProgress)
        let failure = await KanbanLaunchCoordinator.launch(cardId: card.id, board: board, store: store)
        XCTAssertNil(failure)
        let session = try XCTUnwrap(store.locateSession(board.card(id: card.id)!.launchedSessionId!)?.session)
        let command = try XCTUnwrap((session.engine as? TestEngine)?.startedConfigs.first?.environment["KOOKY_AGENT"])
        XCTAssertTrue(command.contains("# Feature: Fresh"), command)
        XCTAssertFalse(command.contains("--resume"), command)
    }

    // MARK: - Skill catalog

    func testSkillCatalogScansProjectUserAndPlugins() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home")
        let project = base.appendingPathComponent("project")
        let fm = FileManager.default

        func write(_ path: String, _ content: String) throws {
            let url = base.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("project/.claude/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: Ship it\n---\n# Deploy")
        try write("project/.claude/commands/review.md", "---\ndescription: \"Review the diff\"\n---\nReview")
        try write("project/.claude/commands/frontend/component.md", "Make a component")
        try write("home/.claude/skills/find-skills/SKILL.md", "---\nname: find-skills\ndescription: Finds skills\n---")
        try write("home/.claude/skills/not-a-skill/README.md", "no manifest here")
        let pluginPath = base.appendingPathComponent("home/.claude/plugins/cache/mkt/al-dev/1.0.0").path
        try write("home/.claude/plugins/cache/mkt/al-dev/1.0.0/skills/plan/SKILL.md", "---\ndescription: Plan AL work\n---")
        try write("home/.claude/plugins/installed_plugins.json", """
        {"version": 2, "plugins": {"al-dev@mkt": [{"installPath": "\(pluginPath)"}]}}
        """)

        let skills = KanbanSkillCatalog.scan(projectRoot: project, home: home)
        let byName = Dictionary(uniqueKeysWithValues: skills.map { ($0.name, $0) })
        XCTAssertEqual(byName["deploy"]?.scope, .project)
        XCTAssertEqual(byName["deploy"]?.description, "Ship it")
        XCTAssertEqual(byName["review"]?.description, "Review the diff", "quoted frontmatter values are unwrapped")
        XCTAssertEqual(byName["frontend:component"]?.scope, .project)
        XCTAssertEqual(byName["find-skills"]?.scope, .user)
        XCTAssertNil(byName["not-a-skill"], "a folder without SKILL.md is not a skill")
        XCTAssertEqual(byName["al-dev:plan"]?.scope, .plugin)
        XCTAssertEqual(byName["al-dev:plan"]?.description, "Plan AL work")
        // Project entries come first so the picker leads with the repo's own.
        XCTAssertEqual(skills.first?.scope, .project)
    }

    func testSkillCatalogIsEmptyWithoutAnyDirectories() {
        let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertTrue(KanbanSkillCatalog.scan(projectRoot: nowhere, home: nowhere).isEmpty)
    }

    func testFrontmatterParsing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fm-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try "---\nname: x\ndescription: 'has: colon'\nweird\n---\nbody: not parsed".write(to: url, atomically: true, encoding: .utf8)
        let front = KanbanSkillCatalog.frontmatter(of: url)
        XCTAssertEqual(front["name"], "x")
        XCTAssertEqual(front["description"], "has: colon")
        XCTAssertNil(front["body"])
        try "no frontmatter".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(KanbanSkillCatalog.frontmatter(of: url).isEmpty)
    }
}
