import Foundation

/// What the card editor and the launch need to know about a card's repo:
/// which branch the main checkout is on, which branches exist, and which
/// of them already live in a worktree. One git round-trip, taken off the
/// main actor by callers.
struct KanbanRepoInfo: Equatable, Sendable {
    var root: URL
    /// Branch checked out at `root` (nil when detached).
    var currentBranch: String?
    /// Local branches, most recently committed first.
    var branches: [String]
    /// Every worktree of the repo, the root included.
    var worktrees: [WorktreeManager.Info]

    /// The branch a fresh card starts on: the main checkout's branch, else
    /// `main` / `master` if they exist, else the newest branch.
    var defaultBranch: String {
        if let currentBranch { return currentBranch }
        for candidate in ["main", "master"] where branches.contains(candidate) { return candidate }
        return branches.first ?? "main"
    }

    /// Worktree (other than the root) that has `branch` checked out.
    func worktreePath(checkingOut branch: String) -> URL? {
        let rootPath = root.standardizedFileURL.path
        return worktrees.first {
            $0.branch == branch && $0.path.standardizedFileURL.path != rootPath
        }?.path
    }

    /// How a launch on `branch` will behave — also the editor's hint line.
    enum BranchPlan: Equatable, Sendable {
        /// Same branch as the main checkout: the agent works in the repo
        /// itself, no worktree.
        case inPlace
        /// Branch already lives in a worktree kooky can adopt.
        case adoptWorktree(URL)
        /// Existing branch, not checked out anywhere → new worktree on it.
        case worktreeOnExistingBranch
        /// Unknown branch → create it (from HEAD) in a new worktree.
        case worktreeOnNewBranch
    }

    func plan(for branch: String) -> BranchPlan {
        if let currentBranch, branch == currentBranch { return .inPlace }
        if let path = worktreePath(checkingOut: branch) { return .adoptWorktree(path) }
        if branches.contains(branch) { return .worktreeOnExistingBranch }
        return .worktreeOnNewBranch
    }

    /// Synchronous git work — callers hop off the main actor.
    static func load(projectRoot: URL) -> KanbanRepoInfo {
        let root = projectRoot.standardizedFileURL
        let worktrees = (try? WorktreeManager.list(repoPath: root).get()) ?? []
        let rootPath = root.path
        let current = worktrees.first { $0.path.standardizedFileURL.path == rootPath }?.branch
        return KanbanRepoInfo(
            root: root,
            currentBranch: current,
            branches: GitBranchInventory.localBranches(cwd: root),
            worktrees: worktrees
        )
    }
}

/// The Ready → In Progress side effect: worktree (or not) + agent tab for
/// a card. Stateless glue between `KanbanStore` (what the card says) and a
/// window's `WorkspaceStore` (where the tab lands). Lives outside both so
/// neither store learns about the other's types.
@MainActor
enum KanbanLaunchCoordinator {
    /// Does the agent still have this conversation on disk? Resuming an id
    /// it can't find makes the CLI exit at once — the board would then read
    /// that exit as "done". Test seam; production asks the session scanner.
    nonisolated(unsafe) static var conversationExists: @Sendable (_ agentRosterId: String, _ conversationId: String) -> Bool = { agent, id in
        AgentSessionScanner.findRecordInDefaultRoot(agentId: agent, conversationId: id) != nil
    }

    /// Git repo root for a workspace, resolved off the main actor (it's a
    /// `git rev-parse` subprocess). Worktree children report their SOURCE
    /// repo's root — cards belong to the project, not to one checkout.
    static func projectRoot(for workspace: Workspace, in store: WorkspaceStore) async -> URL? {
        let anchor: Workspace
        if let parentId = workspace.worktreeParentId,
           let parent = store.workspaces.first(where: { $0.id == parentId }) {
            anchor = parent
        } else {
            anchor = workspace
        }
        guard anchor.sshRemoteHost == nil else { return nil }
        let cwd = anchor.workingDirectory
        return await Task.detached(priority: .userInitiated) {
            WorktreeManager.repoRoot(near: cwd)?.standardizedFileURL
        }.value
    }

    /// Sibling directory next to the repo, `<repo>-<branch-slug>` — the same
    /// default `CreateWorktreeSheet` proposes so CLI-created and card-created
    /// worktrees look alike in Finder.
    static func defaultWorktreePath(projectRoot: URL, branch: String) -> URL {
        let name = WorktreeManager.defaultDirectoryName(
            sourceName: projectRoot.lastPathComponent,
            branch: branch
        )
        return projectRoot.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// `<modelFlag> <model>` for the card's agent, or nil when the model is
    /// blank or the agent has no known flag (the field is then informational).
    static func modelOptions(agentId: String, model: String?) -> String? {
        modelOptions(template: AgentTemplate.all.first { $0.id == agentId }, model: model)
    }

    static func modelOptions(template: AgentTemplate?, model: String?) -> String? {
        guard let flag = template?.modelFlag,
              let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        // Model ids are plain tokens (`opus`, `gpt-5`, `gemini-2.5-pro`);
        // only quote when something shell-significant slipped in, so the
        // command the user sees in the tab title stays `--model opus`.
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:/-[]"))
        let quoted = model.unicodeScalars.allSatisfy { plain.contains($0) }
            ? model
            : KookyShellIntegration.quote(model)
        return "\(flag) \(quoted)"
    }

    /// Copy the live tab's conversation id onto its card. Called before
    /// anything that drops the tab link (a column move away from In
    /// Progress, `card --done`, the completed alert) so a later relaunch
    /// can resume rather than restart.
    static func syncConversationId(card: KanbanCard, board: KanbanStore, store: WorkspaceStore) {
        guard let sessionId = card.launchedSessionId,
              let hit = store.locateSession(sessionId),
              let conversationId = hit.session.conversationId else { return }
        board.recordConversationId(conversationId, forSession: sessionId)
    }

    /// Runs the launch for `cardId` into `store`'s window. Returns nil on
    /// success (the board store is updated via `markLaunched`) or the error
    /// message; on failure the card is bounced back to Ready.
    ///
    /// The agent tab is opened as the window's ACTIVE tab, and a board that
    /// covers the pane host switches to the split layout first: a surface
    /// under a hidden host doesn't spawn its process (libghostty waits for
    /// real geometry — the same reason `open --no-focus` stalls there), and
    /// "moved to In Progress" must mean the agent is visibly working.
    ///
    /// Where the agent lands depends on the card's branch:
    /// - the main checkout's own branch → a tab in the repo itself;
    /// - a branch already in a worktree (pinned earlier, or found via
    ///   `git worktree list`) → a tab in that worktree;
    /// - any other existing branch → a new worktree checking it out;
    /// - an unknown branch → created from HEAD in a new worktree.
    static func launch(cardId: UUID, board: KanbanStore, store: WorkspaceStore) async -> String? {
        guard let card = board.card(id: cardId) else { return "card not found" }
        guard let template = AgentTemplate.all.first(where: { $0.id == card.agentId }), !template.isShell else {
            let message = "agent \(card.agentId) is not available"
            board.markLaunchFailed(id: cardId, message: message)
            return message
        }
        if store.mainContent == .kanban {
            store.setMainContent(.kanbanSplit)
        }
        let source = sourceWorkspace(for: card.projectRoot, in: store)
        let branch = card.branchName
        let extraOptions = modelOptions(template: template, model: card.model)
        // A captured conversation id + an agent that can resume → pick the
        // old conversation back up (it already holds the card's context).
        // The prompt is dropped on purpose: kooky treats a prompt as "fresh
        // question", which suppresses the resume. Verified against the
        // agent's own store first (off-main: it walks ~/.claude/projects).
        var resumeId: String? = nil
        if template.supportsResume, let stored = card.conversationId {
            let roster = template.rosterId
            let exists = await Task.detached(priority: .userInitiated) {
                conversationExists(roster, stored)
            }.value
            if exists {
                resumeId = stored
            } else {
                board.dropConversationId(id: cardId)
            }
        }

        // Re-entry into a worktree the card already owns: adopt it instead
        // of asking git for a second checkout of the same branch.
        if let pinned = card.worktreePath, isDirectory(pinned) {
            return launchInWorktree(
                pinned, card: card, board: board, store: store, source: source,
                template: template, resumeId: resumeId, extraOptions: extraOptions
            )
        }

        let projectRoot = card.projectRoot
        let info = await Task.detached(priority: .userInitiated) {
            KanbanRepoInfo.load(projectRoot: projectRoot)
        }.value

        switch info.plan(for: branch) {
        case .inPlace:
            let prompt = resumeId == nil
                ? card.promptText(workingDirectory: projectRoot, branch: branch, isWorktree: false)
                : nil
            store.activateWorkspace(source)
            let session = store.addTab(
                in: source,
                template: template,
                conversationId: resumeId,
                forceResume: resumeId != nil,
                initialPrompt: prompt,
                extraOptions: extraOptions,
                activate: true
            )
            board.markLaunched(id: cardId, worktreePath: nil, workspaceId: source.id, sessionId: session.id, branch: branch)
            return nil
        case .adoptWorktree(let path):
            return launchInWorktree(
                path, card: card, board: board, store: store, source: source,
                template: template, resumeId: resumeId, extraOptions: extraOptions
            )
        case .worktreeOnExistingBranch, .worktreeOnNewBranch:
            let path = defaultWorktreePath(projectRoot: projectRoot, branch: branch)
            let mode: WorktreeManager.BranchMode = info.plan(for: branch) == .worktreeOnExistingBranch
                ? .existing(branch: branch)
                : .newBranch(name: branch, base: nil)
            let prompt = card.promptText(workingDirectory: path, branch: branch, isWorktree: true)
            switch await store.createWorktreeWorkspace(
                source: source,
                mode: mode,
                path: path,
                branchForDisplay: branch,
                template: template,
                initialPrompt: prompt,
                extraOptions: extraOptions,
                activate: true
            ) {
            case .success(let workspace):
                guard let session = workspace.activeSession else {
                    board.markLaunchFailed(id: cardId, message: "workspace has no session")
                    return "workspace has no session"
                }
                board.markLaunched(id: cardId, worktreePath: path, workspaceId: workspace.id, sessionId: session.id, branch: branch)
                return nil
            case .failure(let error):
                board.markLaunchFailed(id: cardId, message: error.message)
                return error.message
            }
        }
    }

    /// Tab in an existing worktree directory: the sidebar workspace for it
    /// if one is open, else a new child workspace under `source`.
    private static func launchInWorktree(
        _ path: URL,
        card: KanbanCard,
        board: KanbanStore,
        store: WorkspaceStore,
        source: Workspace,
        template: AgentTemplate,
        resumeId: String?,
        extraOptions: String?
    ) -> String? {
        let branch = card.branchName
        let prompt = resumeId == nil
            ? card.promptText(workingDirectory: path, branch: branch, isWorktree: true)
            : nil
        let workspace: Workspace
        let session: Session
        if let existing = store.workspaces.first(where: {
            $0.worktreePath?.standardizedFileURL.path == path.standardizedFileURL.path
        }) {
            workspace = existing
            store.activateWorkspace(existing)
            session = store.addTab(
                in: existing,
                template: template,
                conversationId: resumeId,
                forceResume: resumeId != nil,
                initialPrompt: prompt,
                extraOptions: extraOptions,
                activate: true
            )
        } else {
            workspace = store.addWorkspace(
                workingDirectory: path,
                worktreeParent: source,
                worktreeBranch: branch,
                template: template,
                conversationId: resumeId,
                forceResume: resumeId != nil,
                initialPrompt: prompt,
                extraOptions: extraOptions,
                activate: true
            )
            guard let seed = workspace.activeSession else {
                board.markLaunchFailed(id: card.id, message: "workspace has no session")
                return "workspace has no session"
            }
            session = seed
        }
        board.markLaunched(id: card.id, worktreePath: path, workspaceId: workspace.id, sessionId: session.id, branch: branch)
        return nil
    }

    /// The non-worktree, non-SSH workspace whose cwd sits inside
    /// `projectRoot`, or a fresh one on the repo root when the window has
    /// none — the card must not fail just because the user closed the
    /// project's sidebar entry. Not activated here: the launch activates
    /// whatever workspace the agent tab lands in.
    static func sourceWorkspace(for projectRoot: URL, in store: WorkspaceStore) -> Workspace {
        let rootPath = projectRoot.standardizedFileURL.path
        if let existing = store.workspaces.first(where: { ws in
            ws.worktreeParentId == nil && ws.sshRemoteHost == nil && isInside(ws.workingDirectory, root: rootPath)
        }) {
            return existing
        }
        return store.addWorkspace(workingDirectory: projectRoot, activate: false)
    }

    private static func isInside(_ url: URL, root: String) -> Bool {
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
