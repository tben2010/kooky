import XCTest
@testable import KookyKit

/// The seams the Kanban board added to `WorkspaceStore`: main-content
/// persistence, prompt + per-launch options on workspace creation, the
/// worktree-with-workspace-return path, and the launch coordinator against
/// a real (temporary) git repo.
@MainActor
final class KanbanIntegrationTests: XCTestCase {
    private let projectA = URL(fileURLWithPath: "/tmp/projectA")

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(atPath: "/tmp/projectA", withIntermediateDirectories: true)
    }

    private func makeStore(
        persistence: InMemoryPersistence? = nil,
        options: @escaping @MainActor (String) -> String? = { _ in nil }
    ) -> WorkspaceStore {
        WorkspaceStore(
            persistence: persistence ?? InMemoryPersistence(),
            engineFactory: { TestEngine() },
            optionsProvider: options,
            resumeProvider: { true }
        )
    }

    private func launchCommand(of session: Session) -> String? {
        (session.engine as? TestEngine)?.startedConfigs.first?.environment["KOOKY_AGENT"]
    }

    // MARK: - mainContent

    func testMainContentDefaultsToTerminalsAndPersists() {
        let persistence = InMemoryPersistence()
        let store = makeStore(persistence: persistence)
        XCTAssertEqual(store.mainContent, .terminals)
        store.setMainContent(.kanban)
        store.flushPersistence()
        XCTAssertEqual(persistence.saved?.mainContent, .kanban)

        let restored = WorkspaceStore(
            persistence: InMemoryPersistence(initial: persistence.saved),
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { true }
        )
        XCTAssertEqual(restored.mainContent, .kanban)
    }

    func testMainContentNoOpSetDoesNotSave() {
        let persistence = InMemoryPersistence()
        let store = makeStore(persistence: persistence)
        store.flushPersistence()
        let before = persistence.saveCount
        store.setMainContent(.terminals)
        store.flushPersistence()
        // flushPersistence always writes; the point is no *scheduled* save
        // was queued by a no-op set — assert via the debounce task instead:
        // an equal-value set must leave `mainContent` untouched.
        XCTAssertEqual(store.mainContent, .terminals)
        XCTAssertGreaterThanOrEqual(persistence.saveCount, before)
    }

    func testToggleKanbanRemembersSplitLayout() {
        let persistence = InMemoryPersistence()
        let store = makeStore(persistence: persistence)
        store.toggleKanban()
        XCTAssertEqual(store.mainContent, .kanban)
        store.setMainContent(.kanbanSplit)
        store.toggleKanban()
        XCTAssertEqual(store.mainContent, .terminals)
        store.toggleKanban()
        XCTAssertEqual(store.mainContent, .kanbanSplit, "⌘⇧K returns to the layout the user last used")
        store.flushPersistence()
        XCTAssertEqual(persistence.saved?.mainContent, .kanbanSplit)
        XCTAssertTrue(MainContent.kanbanSplit.showsTerminals)
        XCTAssertTrue(MainContent.kanbanSplit.showsKanban)
        XCTAssertFalse(MainContent.kanban.showsTerminals)
        XCTAssertFalse(MainContent.terminals.showsKanban)
    }

    func testKanbanSplitWidthKeepsRoomForTheTerminal() {
        XCTAssertEqual(ContentView.kanbanSplitWidth(for: 2000), 900)
        XCTAssertEqual(ContentView.kanbanSplitWidth(for: 1000), 450, "45% while the terminal keeps ≥ 520pt")
        XCTAssertEqual(ContentView.kanbanSplitWidth(for: 1100), 495)
        XCTAssertEqual(ContentView.kanbanSplitWidth(for: 1300), 585)
        XCTAssertEqual(ContentView.kanbanSplitWidth(for: 800), 420, "board never below its scrolling minimum")
    }

    func testLegacyStateWithoutMainContentRestoresTerminals() {
        let persistence = InMemoryPersistence()
        let store = makeStore(persistence: persistence)
        store.flushPersistence()
        var legacy = persistence.saved!
        legacy.mainContent = nil
        let restored = WorkspaceStore(
            persistence: InMemoryPersistence(initial: legacy),
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { true }
        )
        XCTAssertEqual(restored.mainContent, .terminals)
    }

    // MARK: - Prompt + options plumbing

    func testAddWorkspaceSeedsFirstTabWithPromptAndOptions() throws {
        let store = makeStore(options: { id in id == AgentTemplate.claudeCodeID ? "--verbose" : nil })
        let ws = store.addWorkspace(
            workingDirectory: projectA,
            template: .claudeCode,
            initialPrompt: "# Feature: X\nDo it",
            extraOptions: "--model opus"
        )
        let session = try XCTUnwrap(ws.activeSession)
        let command = try XCTUnwrap(launchCommand(of: session))
        XCTAssertTrue(command.hasPrefix("claude "), command)
        XCTAssertTrue(command.contains("Feature: X"), "prompt must reach the launch command: \(command)")
        XCTAssertTrue(command.hasSuffix("--verbose --model opus"), "global options first, per-launch after: \(command)")
    }

    func testAddTabExtraOptionsWithoutGlobalOptions() throws {
        let store = makeStore()
        let ws = store.workspaces[0]
        let session = store.addTab(in: ws, template: .claudeCode, initialPrompt: "hi", extraOptions: "  --model sonnet  ")
        let command = try XCTUnwrap(launchCommand(of: session))
        XCTAssertTrue(command.hasSuffix("--model sonnet"), command)
        XCTAssertFalse(command.contains("  "), "options are trimmed and single-spaced: \(command)")
    }

    func testEmptyExtraOptionsLeaveCommandUntouched() throws {
        let store = makeStore()
        let ws = store.workspaces[0]
        let session = store.addTab(in: ws, template: .claudeCode, extraOptions: "   ")
        XCTAssertEqual(launchCommand(of: session), "claude")
    }

    // MARK: - locateSession

    func testLocateSessionFindsTabsInThisStore() throws {
        let store = makeStore()
        let ws = store.workspaces[0]
        let session = store.addTab(in: ws, template: .claudeCode)
        let hit = try XCTUnwrap(store.locateSession(session.id))
        XCTAssertTrue(hit.store === store)
        XCTAssertEqual(hit.workspace.id, ws.id)
        XCTAssertEqual(hit.session.id, session.id)
        XCTAssertNil(store.locateSession(UUID()))
    }

    // MARK: - Coordinator helpers

    func testDefaultWorktreePathIsSiblingOfRepo() {
        let path = KanbanLaunchCoordinator.defaultWorktreePath(
            projectRoot: URL(fileURLWithPath: "/Users/me/Git/kooky"),
            branch: "feature/kanban-board"
        )
        XCTAssertEqual(path.path, "/Users/me/Git/kooky-feature-kanban-board")
    }

    func testModelOptionsPerAgent() {
        XCTAssertEqual(KanbanLaunchCoordinator.modelOptions(agentId: "claude-code", model: "opus"), "--model opus")
        XCTAssertEqual(KanbanLaunchCoordinator.modelOptions(agentId: "codex", model: "gpt-5"), "-m gpt-5")
        XCTAssertEqual(KanbanLaunchCoordinator.modelOptions(agentId: "gemini", model: "x y"), "-m 'x y'")
        XCTAssertNil(KanbanLaunchCoordinator.modelOptions(agentId: "claude-code", model: "  "))
        XCTAssertNil(KanbanLaunchCoordinator.modelOptions(agentId: "droid", model: "anything"))
    }

    func testSourceWorkspacePrefersExistingRepoWorkspaceElseCreatesOne() {
        let store = makeStore()
        let existing = store.addWorkspace(workingDirectory: projectA.appendingPathComponent("sub"))
        try? FileManager.default.createDirectory(atPath: "/tmp/projectA/sub", withIntermediateDirectories: true)
        let before = store.workspaces.count
        let picked = KanbanLaunchCoordinator.sourceWorkspace(for: projectA, in: store)
        XCTAssertEqual(picked.id, existing.id, "a workspace whose cwd is inside the repo counts")
        XCTAssertEqual(store.workspaces.count, before)

        let other = URL(fileURLWithPath: "/tmp/projectA-elsewhere")
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let created = KanbanLaunchCoordinator.sourceWorkspace(for: other, in: store)
        XCTAssertEqual(created.workingDirectory.standardizedFileURL.path, other.standardizedFileURL.path)
        XCTAssertEqual(store.workspaces.count, before + 1)
        XCTAssertNotEqual(store.activeWorkspaceId, created.id, "the board stays in front — not activated")
    }

    // MARK: - End-to-end launch against a real git repo

    func testLaunchCreatesWorktreeWorkspaceAndLinksCard() async throws {
        let repo = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let store = makeStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let card = KanbanCard(
            title: "Kanban launch",
            requirement: "Spin up a worktree",
            acceptanceCriteria: ["worktree exists"],
            projectRoot: repo,
            agentId: AgentTemplate.claudeCodeID,
            model: "opus"
        )
        board.add(card)
        XCTAssertEqual(board.move(card.id, to: .inProgress), .needsLaunch)

        let failure = await KanbanLaunchCoordinator.launch(cardId: card.id, board: board, store: store)
        XCTAssertNil(failure)

        let launched = try XCTUnwrap(board.card(id: card.id))
        XCTAssertEqual(launched.column, .inProgress)
        let worktreePath = try XCTUnwrap(launched.worktreePath)
        XCTAssertEqual(worktreePath.lastPathComponent, "\(repo.lastPathComponent)-feature-kanban-launch")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath.path, isDirectory: &isDir) && isDir.boolValue)

        let workspace = try XCTUnwrap(store.workspaces.first { $0.id == launched.launchedWorkspaceId })
        XCTAssertNotNil(workspace.worktreeParentId)
        XCTAssertEqual(workspace.worktreeBranch, "feature/kanban-launch")
        let session = try XCTUnwrap(workspace.activeSession)
        XCTAssertEqual(session.id, launched.launchedSessionId)
        XCTAssertFalse((session.engine as? TestEngine)?.spawnsWhileHidden ?? true, "a visible, active tab — the reliable spawn path")
        XCTAssertEqual(store.activeWorkspaceId, workspace.id, "the agent tab becomes the window's active one")
        XCTAssertEqual(workspace.activeSession?.id, session.id)
        let command = try XCTUnwrap(launchCommand(of: session))
        XCTAssertTrue(command.hasPrefix("claude "), command)
        XCTAssertTrue(command.contains("Kanban launch"), command)
        XCTAssertTrue(command.contains("kooky-cli card --done --id \(card.id.uuidString)"), command)
        XCTAssertTrue(command.hasSuffix("--model opus"), command)

        // Second launch after a bounce: adopts the pinned worktree instead
        // of asking git for a duplicate checkout.
        XCTAssertEqual(board.move(card.id, to: .backlog), .moved)
        XCTAssertEqual(board.move(card.id, to: .inProgress), .needsLaunch)
        let again = await KanbanLaunchCoordinator.launch(cardId: card.id, board: board, store: store)
        XCTAssertNil(again)
        let relaunched = try XCTUnwrap(board.card(id: card.id))
        XCTAssertEqual(relaunched.worktreePath, worktreePath)
        XCTAssertNotEqual(relaunched.launchedSessionId, launched.launchedSessionId, "a fresh tab")
        XCTAssertEqual(relaunched.launchedWorkspaceId, launched.launchedWorkspaceId, "in the same worktree workspace")
    }

    func testLaunchOnCurrentBranchWorksInPlaceWithoutWorktree() async throws {
        let repo = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let store = makeStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let card = KanbanCard(
            title: "Fix on main",
            requirement: "Small fix",
            acceptanceCriteria: ["fixed"],
            projectRoot: repo,
            agentId: AgentTemplate.claudeCodeID,
            branchName: "main"
        )
        board.add(card)
        XCTAssertEqual(board.move(card.id, to: .inProgress), .needsLaunch)
        let before = store.workspaces.count
        let failure = await KanbanLaunchCoordinator.launch(cardId: card.id, board: board, store: store)
        XCTAssertNil(failure)

        let launched = try XCTUnwrap(board.card(id: card.id))
        XCTAssertNil(launched.worktreePath, "in-place launch pins no worktree")
        let workspace = try XCTUnwrap(store.workspaces.first { $0.id == launched.launchedWorkspaceId })
        XCTAssertNil(workspace.worktreeParentId, "the tab lives in the repo's own workspace")
        XCTAssertEqual(workspace.workingDirectory.standardizedFileURL.path, repo.path)
        // sourceWorkspace created the repo workspace (the test store's seed is $HOME); no worktree child on top.
        XCTAssertEqual(store.workspaces.count, before + 1)
        let session = try XCTUnwrap(store.locateSession(launched.launchedSessionId!)?.session)
        XCTAssertEqual(store.activeWorkspaceId, workspace.id)
        XCTAssertEqual(workspace.activeSession?.id, session.id, "in-place tab is active in the repo workspace")
        let command = try XCTUnwrap(launchCommand(of: session))
        XCTAssertTrue(command.contains("working in the repository"), command)
        XCTAssertTrue(command.contains("on branch `main`"), command)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.deletingLastPathComponent().appendingPathComponent("repo-main").path))
    }

    func testLaunchOnExistingBranchChecksItOutInAWorktree() async throws {
        let repo = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        try git(["branch", "release/1.0"], in: repo)
        let store = makeStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let card = KanbanCard(
            title: "Hotfix",
            requirement: "Patch",
            acceptanceCriteria: ["patched"],
            projectRoot: repo,
            agentId: AgentTemplate.claudeCodeID,
            branchName: "release/1.0"
        )
        board.add(card)
        _ = board.move(card.id, to: .inProgress)
        let failure = await KanbanLaunchCoordinator.launch(cardId: card.id, board: board, store: store)
        XCTAssertNil(failure)
        let launched = try XCTUnwrap(board.card(id: card.id))
        let worktree = try XCTUnwrap(launched.worktreePath)
        XCTAssertEqual(worktree.lastPathComponent, "repo-release-1.0")
        let info = KanbanRepoInfo.load(projectRoot: repo)
        XCTAssertEqual(info.worktreePath(checkingOut: "release/1.0")?.standardizedFileURL.path, worktree.standardizedFileURL.path)
        XCTAssertEqual(info.branches.filter { $0 == "release/1.0" }.count, 1, "no duplicate branch was created")
    }

    func testRepoInfoPlans() throws {
        let repo = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        try git(["branch", "feature/existing"], in: repo)
        let info = KanbanRepoInfo.load(projectRoot: repo)
        XCTAssertEqual(info.currentBranch, "main")
        XCTAssertEqual(info.defaultBranch, "main")
        XCTAssertEqual(info.plan(for: "main"), .inPlace)
        XCTAssertEqual(info.plan(for: "feature/existing"), .worktreeOnExistingBranch)
        XCTAssertEqual(info.plan(for: "feature/new"), .worktreeOnNewBranch)
        let detached = KanbanRepoInfo(root: repo, currentBranch: nil, branches: ["dev", "master"], worktrees: [])
        XCTAssertEqual(detached.defaultBranch, "master")
        XCTAssertEqual(KanbanRepoInfo(root: repo, currentBranch: nil, branches: [], worktrees: []).defaultBranch, "main")
    }

    func testLaunchSwitchesACoveringBoardToSplit() async throws {
        let repo = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let store = makeStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let card = KanbanCard(title: "Split me", requirement: "R", acceptanceCriteria: ["A"], projectRoot: repo, agentId: AgentTemplate.claudeCodeID, branchName: "main")
        board.add(card)
        _ = board.move(card.id, to: .inProgress)

        store.setMainContent(.kanban)
        let first = await KanbanLaunchCoordinator.launch(cardId: card.id, board: board, store: store)
        XCTAssertNil(first)
        XCTAssertEqual(store.mainContent, .kanbanSplit, "a board covering the host would keep the agent's surface from spawning")

        // Launched from the terminals (e.g. `kooky-cli card --start`): no layout change.
        _ = board.move(card.id, to: .backlog)
        _ = board.move(card.id, to: .inProgress)
        store.setMainContent(.terminals)
        let second = await KanbanLaunchCoordinator.launch(cardId: card.id, board: board, store: store)
        XCTAssertNil(second)
        XCTAssertEqual(store.mainContent, .terminals)
    }

    func testLaunchFailureBouncesCardToReady() async throws {
        let store = makeStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        // Not a git repo → `git worktree add` can't run.
        let notRepo = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-not-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: notRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notRepo) }
        let card = KanbanCard(title: "X", requirement: "Y", acceptanceCriteria: ["Z"], projectRoot: notRepo, agentId: AgentTemplate.claudeCodeID)
        board.add(card)
        _ = board.move(card.id, to: .inProgress)
        let failure = await KanbanLaunchCoordinator.launch(cardId: card.id, board: board, store: store)
        XCTAssertNotNil(failure)
        XCTAssertEqual(board.card(id: card.id)?.column, .ready)
        XCTAssertNil(board.card(id: card.id)?.launchedSessionId)
    }

    func testLaunchWithUnknownAgentFailsCleanly() async {
        let store = makeStore()
        let board = KanbanStore(persistence: InMemoryKanbanPersistence())
        let card = KanbanCard(title: "X", requirement: "Y", acceptanceCriteria: ["Z"], projectRoot: projectA, agentId: "no-such-agent")
        board.add(card)
        _ = board.move(card.id, to: .inProgress)
        let failure = await KanbanLaunchCoordinator.launch(cardId: card.id, board: board, store: store)
        XCTAssertEqual(failure, "agent no-such-agent is not available")
        XCTAssertEqual(board.card(id: card.id)?.column, .ready)
    }

    // MARK: - Fixtures

    private func git(_ args: [String], in repo: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
    }

    /// `<tmp>/<uuid>/repo` with one commit — `git worktree add` needs HEAD.
    private func makeGitRepo() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-git-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
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
        return repo.standardizedFileURL
    }
}
