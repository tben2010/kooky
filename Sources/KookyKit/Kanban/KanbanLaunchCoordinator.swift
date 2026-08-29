import Foundation

/// The Ready → In Progress side effect: worktree + agent tab for a card.
/// Stateless glue between `KanbanStore` (what the card says) and a window's
/// `WorkspaceStore` (where the tab lands). Lives outside both so neither
/// store learns about the other's types.
@MainActor
enum KanbanLaunchCoordinator {
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

    /// Per-agent spelling of a model override. Phase 1 knows the three CLIs
    /// whose flag is stable; unknown agents get no flag (the card's model
    /// field is then informational only).
    static func modelOptions(agentId: String, model: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        // Model ids are plain tokens (`opus`, `gpt-5`, `gemini-2.5-pro`);
        // only quote when something shell-significant slipped in, so the
        // command the user sees in the tab title stays `--model opus`.
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:/-"))
        let quoted = model.unicodeScalars.allSatisfy { plain.contains($0) }
            ? model
            : KookyShellIntegration.quote(model)
        switch agentId {
        case AgentTemplate.claudeCodeID: return "--model \(quoted)"
        case "codex", "gemini", "antigravity": return "-m \(quoted)"
        default: return nil
        }
    }

    /// Runs the launch for `cardId` into `store`'s window. Returns nil on
    /// success (the board store is updated via `markLaunched`) or the error
    /// message; on failure the card is bounced back to Ready.
    static func launch(cardId: UUID, board: KanbanStore, store: WorkspaceStore) async -> String? {
        guard let card = board.card(id: cardId) else { return "card not found" }
        guard let template = AgentTemplate.all.first(where: { $0.id == card.agentId }), !template.isShell else {
            let message = "agent \(card.agentId) is not available"
            board.markLaunchFailed(id: cardId, message: message)
            return message
        }
        let source = sourceWorkspace(for: card.projectRoot, in: store)
        let branch = card.branchName
        let extraOptions = modelOptions(agentId: card.agentId, model: card.model)

        // Re-entry: the card already owns a worktree on disk (moved back to
        // Backlog earlier). Adopt it instead of asking git for a second
        // checkout of the same branch, which it would refuse.
        if let pinned = card.worktreePath, isDirectory(pinned) {
            let prompt = card.promptText(worktreePath: pinned, branch: branch)
            let workspace: Workspace
            let session: Session
            if let existing = store.workspaces.first(where: {
                $0.worktreePath?.standardizedFileURL.path == pinned.standardizedFileURL.path
            }) {
                workspace = existing
                session = store.addTab(in: existing, template: template, initialPrompt: prompt, extraOptions: extraOptions)
            } else {
                workspace = store.addWorkspace(
                    workingDirectory: pinned,
                    worktreeParent: source,
                    worktreeBranch: branch,
                    template: template,
                    initialPrompt: prompt,
                    extraOptions: extraOptions,
                    activate: false
                )
                guard let seed = workspace.activeSession else {
                    board.markLaunchFailed(id: cardId, message: "workspace has no session")
                    return "workspace has no session"
                }
                session = seed
            }
            board.markLaunched(id: cardId, worktreePath: pinned, workspaceId: workspace.id, sessionId: session.id, branch: branch)
            return nil
        }

        let path = defaultWorktreePath(projectRoot: card.projectRoot, branch: branch)
        let prompt = card.promptText(worktreePath: path, branch: branch)
        switch await store.createWorktreeWorkspace(
            source: source,
            mode: .newBranch(name: branch, base: nil),
            path: path,
            branchForDisplay: branch,
            template: template,
            initialPrompt: prompt,
            extraOptions: extraOptions
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

    /// The non-worktree, non-SSH workspace whose cwd sits inside
    /// `projectRoot`, or a fresh one on the repo root when the window has
    /// none — the card must not fail just because the user closed the
    /// project's sidebar entry. Not activated: the board stays in front.
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
