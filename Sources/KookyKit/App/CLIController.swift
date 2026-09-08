import AppKit
import Foundation
import KookyHookKit
import os

/// Runs a blocking filesystem call off the main actor and GIVES UP on it
/// after `timeout`, returning nil.
///
/// The giving up is the whole point. `work` is a synchronous `realpath` /
/// `stat`, which on a disconnected network volume or a dead automount blocks
/// for the mount timeout — and a blocked synchronous call cannot be
/// cancelled. So `await Task.detached { work() }.value` waits however long
/// the volume takes, and a deadline checked AFTER that await can never fire
/// (it only measures how long a call that DID return took). Racing a sleeper
/// is what actually bounds the wait.
///
/// A `TaskGroup` cannot express this: it implicitly awaits every child
/// before returning, so the stuck one would hold the group open anyway.
/// Hence the continuation plus a one-shot gate.
///
/// The abandoned work still occupies a thread until the filesystem gives up.
/// That is unavoidable, bounded by the mount timeout, and harmless: its
/// result is dropped and it writes to nothing.
/// The wall-clock budget for ONE request, measured from when it arrived.
///
/// This is not the same thing as `withOffMainTimeout`, and collapsing the
/// two has already caused one regression: that helper bounds a single piece
/// of blocking work, while this bounds the request. A probe can win its own
/// race in two seconds and then sit in the MainActor queue past the caller's
/// timeout — the caller has already been told the request failed, and
/// spawning anyway means the command runs while its invoker believes it
/// didn't.
///
/// Check it immediately before any SIDE EFFECT — spawning a tab, building or
/// fronting a window, activating the app — not merely after an `await`.
struct RequestDeadline {
    private let expiresAt: ContinuousClock.Instant

    init(_ budget: Duration) {
        expiresAt = ContinuousClock.now.advanced(by: budget)
    }

    var hasExpired: Bool { ContinuousClock.now >= expiresAt }
}

func withOffMainTimeout<T: Sendable>(
    _ timeout: Duration,
    work: @escaping @Sendable () -> T
) async -> T? {
    let gate = OneShotGate()
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        Task.detached(priority: .userInitiated) {
            let value = work()
            if gate.tryEnter() { continuation.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(for: timeout)
            if gate.tryEnter() { continuation.resume(returning: nil) }
        }
    }
}

/// Lets exactly one of two racing tasks resume the continuation.
private final class OneShotGate: Sendable {
    private let fired = OSAllocatedUnfairLock(initialState: false)
    func tryEnter() -> Bool {
        fired.withLock { alreadyFired in
            if alreadyFired { return false }
            alreadyFired = true
            return true
        }
    }
}

/// How a resume request (deep link or CLI) ended. `failed` reasons are
/// user-facing text; `dropped` covers the deliberately silent tiers the
/// deep-link path has always had (mid-quit, lookup timeout) — the deep-link
/// wrapper only logs those, while the CLI still answers its caller with the
/// reason.
enum ResumeRequestOutcome: Equatable {
    /// The conversation was already open; kooky jumped to its tab.
    case revealed
    /// Resumed into a new tab.
    case opened
    case failed(String)
    case dropped(String)
}

/// App-side executor for `kooky-cli` verbs. `HookServer` owns the transport
/// (one request line in, one response line out); this owns the decisions.
/// Everything that touches AppKit windows or the deep-link pipeline is
/// injected, so verb logic is unit-testable against `TestEngine` stores —
/// the same split DeepLinkTests uses (pure decisions pinned, window
/// fronting manual).
@MainActor
final class KookyCLIController {
    /// One kooky window as the CLI sees it. `isKey` means "the window kooky
    /// considers active" (last key when the app is in the background — CLI
    /// calls almost always arrive while kooky is NOT frontmost, when AppKit
    /// reports no key window at all). `reveal` fronts the window and
    /// activates the given workspace + tab; `window` anchors sheets.
    struct WindowContext {
        let store: WorkspaceStore
        let isKey: Bool
        let reveal: @MainActor (Session, Workspace) -> Void
        var window: @MainActor () -> NSWindow? = { nil }
    }

    private let appVersion: String
    private let windows: @MainActor () -> [WindowContext]
    /// Zero-window fallback (Settings/About can keep the app alive with no
    /// terminal window) — mirrors `deepLinkController()`, may create a
    /// window. Nil means the app is shutting down. `builtWindow` reports
    /// whether a window was actually created for this call, which decides
    /// whether its seed tab is ours to discard: it is a FACT from the window
    /// layer, not something to re-derive here — the fallback can still find
    /// a usable controller even when this controller saw no windows.
    private let fallbackWindow: @MainActor () -> (context: WindowContext, builtWindow: Bool)?
    private let activateApp: @MainActor () -> Void
    /// True once `applicationWillTerminate` has run. A verb that hops off
    /// the main actor must re-ask on the way back: the ⌘Q drain flushes
    /// every store to state.json, and a session added after that flush is
    /// both lost and briefly alive.
    private let isShuttingDown: @MainActor () -> Bool
    /// The templates `open --agent` may launch: built-ins + Settings →
    /// Agents customs (hidden ones included — an external script shouldn't
    /// break because a template was hidden from the `+` menu) + terminal
    /// presets. One roster serves both the lookup and the error hint, so
    /// the ids an error lists are exactly the ids the lookup accepts.
    private let templates: @MainActor () -> [AgentTemplate]
    /// The Kanban board `card` verbs act on. Injected so tests drive an
    /// isolated store; production resolves the shared one lazily.
    private let board: @MainActor () -> KanbanStore
    private let resume: @MainActor (
        _ agentId: String,
        _ conversationId: String,
        _ cwd: String?,
        _ isCallerWaiting: @escaping @MainActor () -> Bool,
        _ completion: @escaping @MainActor (ResumeRequestOutcome) -> Void
    ) -> Void

    init(
        appVersion: String,
        windows: @escaping @MainActor () -> [WindowContext],
        fallbackWindow: @escaping @MainActor () -> (context: WindowContext, builtWindow: Bool)?,
        activateApp: @escaping @MainActor () -> Void,
        isShuttingDown: @escaping @MainActor () -> Bool = { false },
        templates: @escaping @MainActor () -> [AgentTemplate],
        board: @escaping @MainActor () -> KanbanStore = { .shared },
        resume: @escaping @MainActor (
            _ agentId: String,
            _ conversationId: String,
            _ cwd: String?,
            _ isCallerWaiting: @escaping @MainActor () -> Bool,
            _ completion: @escaping @MainActor (ResumeRequestOutcome) -> Void
        ) -> Void
    ) {
        self.appVersion = appVersion
        self.windows = windows
        self.fallbackWindow = fallbackWindow
        self.activateApp = activateApp
        self.isShuttingDown = isShuttingDown
        self.templates = templates
        self.board = board
        self.resume = resume
    }

    /// Calls `completion` exactly once on every path — the completion owns
    /// the client fd (see `HookServer.CLIHandler`).
    func handle(
        _ request: KookyCLIRequest,
        isCallerWaiting: @escaping @MainActor () -> Bool = { true },
        completion: @escaping @MainActor (KookyCLIResponse) -> Void
    ) {
        // Deliberate second gate: the socket path is already covered by
        // HookServer's pre-decode peek (which users actually hit); this one
        // keeps direct callers honest and shares the message so the two
        // can't drift.
        guard request.protocolVersion <= KookyCLIProtocol.version else {
            completion(refuse(KookyCLIProtocol.tooNewRequestMessage(requested: request.protocolVersion)))
            return
        }
        guard let verb = KookyCLIVerb(rawValue: request.verb) else {
            completion(refuse("unknown verb '\(request.verb)'"))
            return
        }
        switch verb {
        case .status:
            completion(ok())
        case .list:
            completion(ok(windows: listWindows()))
        case .focus:
            completion(handleFocus(request))
        case .close:
            completion(handleClose(request))
        case .rename:
            completion(handleRename(request))
        case .open:
            handleOpen(request, isCallerWaiting: isCallerWaiting, completion: completion)
        case .resume:
            handleResume(request, isCallerWaiting: isCallerWaiting, completion: completion)
        case .card:
            handleCard(request, completion: completion)
        }
    }

    // MARK: - Kanban card

    /// `card --done | --note | --show`. The card comes from `--id`, or —
    /// the shape the launch prompt relies on — from the invoking tab
    /// (`surface`), matched against the card that launched that session.
    private func handleCard(_ request: KookyCLIRequest, completion: @escaping @MainActor (KookyCLIResponse) -> Void) {
        let board = board()
        if request.cardAction == "new" {
            return handleNewCard(request, board: board, completion: completion)
        }
        let card: KanbanCard
        if let raw = request.cardId {
            guard let id = UUID(uuidString: raw) else {
                return completion(refuse("--id expects a card UUID"))
            }
            if let found = board.card(id: id) {
                card = found
            } else if let archivedCard = board.archivedCard(id: id) {
                // An archived card is still a fact an agent may ask about,
                // but not something to move or annotate from a shell.
                guard request.cardAction == "show" else {
                    return completion(refuse("card \"\(archivedCard.title)\" is archived — restore it from the board's archive first"))
                }
                return completion(ok(note: Self.renderCard(archivedCard, archived: true)))
            } else {
                return completion(refuse("no card with id \(id.uuidString)"))
            }
        } else if let raw = request.surface, let surface = UUID(uuidString: raw) {
            guard let found = board.card(launchedSession: surface) else {
                return completion(refuse("this tab was not launched from a Kanban card — pass --id <card-uuid>"))
            }
            card = found
        } else {
            return completion(refuse("card needs --id <card-uuid> (or run it inside the card's agent tab)"))
        }
        if request.cardAction == "start" {
            // Same path as dragging the card to In Progress: move, then
            // launch into the key window (or the fallback window).
            guard let context = windows().first(where: \.isKey) ?? windows().first ?? fallbackWindow()?.context else {
                return completion(refuse("kooky has no window to launch into"))
            }
            let outcome = board.move(card.id, to: .inProgress)
            // In Progress with no live tab (kooky was restarted, or the tab
            // was closed): a relaunch is what the caller means.
            let deadInProgress: Bool = {
                guard case .moved = outcome, card.column == .inProgress else { return false }
                return card.launchedSessionId.flatMap(locate) == nil
            }()
            switch outcome {
            case .rejected(let reasons):
                return completion(refuse("card is not ready: \(reasons.joined(separator: ", "))"))
            case .moved where !deadInProgress:
                return completion(ok(note: "card \"\(card.title)\" is already running — nothing launched"))
            case .moved, .needsLaunch:
                Task { @MainActor in
                    if let failure = await KanbanLaunchCoordinator.launch(cardId: card.id, board: board, store: context.store) {
                        completion(self.refuse("launch failed: \(failure)"))
                    } else {
                        let launched = board.card(id: card.id)
                        completion(self.ok(
                            tabId: launched?.launchedSessionId?.uuidString,
                            note: "launched \(launched?.agentId ?? card.agentId) for \"\(card.title)\" on \(launched?.branchName ?? card.branchName)"
                        ))
                    }
                }
                return
            }
        }
        completion(handleCardSync(request, card: card, board: board))
    }

    /// `card --new`: a Backlog card for the repo around `cwd`. The git root
    /// and (when `--branch` is absent) the checked-out branch come from a
    /// subprocess, so both resolve off the main actor — same reason `open`
    /// stats its cwd there. Nothing is launched; the note carries the id
    /// so a script can follow up with `card --start --id`.
    private func handleNewCard(_ request: KookyCLIRequest, board: KanbanStore, completion: @escaping @MainActor (KookyCLIResponse) -> Void) {
        guard let title = request.title.flatMap(normalizedTitle) else {
            return completion(refuse("--title needs text"))
        }
        guard let cwd = request.cwd, !cwd.isEmpty else {
            return completion(refuse("card --new needs --cwd <dir> (a directory inside the project's git repository)"))
        }
        guard cwd.hasPrefix("/") else {
            return completion(refuse("cwd must be an absolute path"))
        }
        let agentId = request.agent ?? AgentTemplate.claudeCodeID
        guard let template = lookupTemplate(agentId) else {
            let known = templates().map(\.id).joined(separator: ", ")
            return completion(refuse("unknown agent template '\(agentId)' — known templates: \(known)"))
        }
        let requirement = request.requirement?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let criteria = request.criteria.map(KanbanCard.criteria(fromLines:)) ?? []
        let requestedBranch = request.branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwdURL = URL(fileURLWithPath: cwd)
        Task { @MainActor in
            let resolved: (root: URL, branch: String)? = await Task.detached(priority: .userInitiated) {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: cwdURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
                      let root = WorktreeManager.repoRoot(near: cwdURL)
                else { return nil }
                if let requestedBranch, !requestedBranch.isEmpty { return (root, requestedBranch) }
                return (root, KanbanRepoInfo.load(projectRoot: root).defaultBranch)
            }.value
            guard let resolved else {
                return completion(self.refuse("\(cwd) is not inside a git repository — cards belong to a repo"))
            }
            let card = KanbanCard(
                title: title,
                requirement: requirement,
                acceptanceCriteria: criteria,
                projectRoot: resolved.root,
                agentId: template.id,
                branchName: resolved.branch
            )
            board.add(card)
            completion(self.ok(note: "created card \(card.id.uuidString) — \"\(card.title)\" in Backlog of \(resolved.root.path) on \(card.branchName)"))
        }
    }

    private func handleCardSync(_ request: KookyCLIRequest, card: KanbanCard, board: KanbanStore) -> KookyCLIResponse {
        // Capture the agent's conversation id while its tab is still alive —
        // a later relaunch resumes it instead of starting over.
        if let sessionId = card.launchedSessionId,
           let hit = locate(sessionId),
           let conversationId = hit.session.conversationId {
            board.recordConversationId(conversationId, forSession: sessionId)
        }
        switch request.cardAction {
        case "done":
            guard card.column == .inProgress else {
                return ok(note: "card \"\(card.title)\" is in \(card.column.rawValue), not In Progress — nothing moved")
            }
            board.move(card.id, to: .inReview)
            return ok(note: "card \"\(card.title)\" moved to In Review")
        case "note":
            guard let text = request.note?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return refuse("--note needs text")
            }
            board.appendNote(id: card.id, text: text)
            return ok(note: "noted on \"\(card.title)\"")
        case "show":
            return ok(note: Self.renderCard(card))
        default:
            return refuse("card needs one of --start, --done, --note <text>, --show")
        }
    }

    /// Plain-text card summary for `card --show` — what an agent reads
    /// back to re-orient itself.
    static func renderCard(_ card: KanbanCard, archived: Bool = false) -> String {
        var lines: [String] = []
        lines.append("card \(card.id.uuidString)")
        lines.append("title: \(card.title)")
        lines.append("column: \(card.column.rawValue)")
        if archived { lines.append("archived: yes") }
        lines.append("branch: \(card.branchName)")
        if let worktree = card.worktreePath { lines.append("worktree: \(worktree.path)") }
        lines.append("agent: \(card.agentId)\(card.model.map { " (\($0))" } ?? "")")
        lines.append("")
        lines.append("requirement:")
        lines.append(card.requirement)
        lines.append("")
        lines.append("acceptance criteria:")
        for criterion in card.effectiveCriteria { lines.append("- [ ] \(criterion)") }
        let notes = card.events.filter { $0.message.hasPrefix("note: ") }
        if !notes.isEmpty {
            lines.append("")
            lines.append("notes:")
            for note in notes.suffix(10) { lines.append("- \(note.message.dropFirst("note: ".count))") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Verbs

    private func handleFocus(_ request: KookyCLIRequest) -> KookyCLIResponse {
        guard let id = sessionUUID(request) else {
            return refuse("focus needs --tab <session-uuid>")
        }
        guard let hit = locate(id) else {
            return refuse("no tab with id \(id.uuidString) — run `kooky-cli list`")
        }
        activateApp()
        hit.context.reveal(hit.session, hit.workspace)
        return ok(note: "focused")
    }

    private func handleClose(_ request: KookyCLIRequest) -> KookyCLIResponse {
        guard let id = sessionUUID(request) else {
            return refuse("close needs --tab <session-uuid>")
        }
        guard let hit = locate(id) else {
            return refuse("no tab with id \(id.uuidString) — run `kooky-cli list`")
        }
        // The last tab of a worktree workspace cascades into "remove the
        // worktree directory" with its own sidebar-hosted confirmation —
        // a flow a background CLI call can't honestly drive (the sheet may
        // not even mount). Refuse loudly instead of reporting a close that
        // didn't happen. Same predicate closeTab's reroute uses.
        if hit.workspace.closingLastTabCascadesIntoWorktreeRemoval {
            return refuse("that tab is the last one of a worktree workspace — closing it removes the worktree, which needs in-app confirmation")
        }
        // Same semantics as the tab's own ✕ / ⌘W: the shared ConfirmCloseTab
        // entry honors `terminal.confirm-close-surface`. When it will ask,
        // bring the tab on screen first so the sheet lands somewhere visible
        // (and pass the window explicitly — with kooky in the background a
        // detached engine view plus no key window would otherwise skip the
        // confirmation entirely and kill the process); a plain close stays
        // silent in the background. The note reports what request() actually
        // DID, not the pre-read — the two can differ (no anchorable window).
        switch ConfirmCloseTab.request(
            hit.session,
            in: hit.workspace,
            store: hit.context.store,
            anchorWindow: hit.context.window(),
            // Front + reveal ONLY when a confirmation is actually going to be
            // on screen. A `.windowBusy` refusal changed nothing, so it must
            // not change what the user is looking at either — and revealing B
            // under a sheet that asks about A is worse than not revealing.
            willPresent: { [weak self] in
                self?.activateApp()
                hit.context.reveal(hit.session, hit.workspace)
            }
        ) {
        case .closed:
            return ok(note: "closed")
        case .confirming:
            return ok(note: "confirmation shown in kooky")
        case .windowBusy:
            // The sheet already on that window belongs to another tab and
            // will never decide this one — reporting "confirmation shown"
            // would leave the caller waiting on a dialog that isn't about
            // its tab. Retrying after the user answers works.
            return refuse("that tab's window already has a close confirmation waiting for another tab — answer it first")
        }
    }

    /// Pure metadata: never activates the app or fronts a window. Uses the
    /// same store entry the in-app rename popover commits through, so
    /// normalize/dedup/persist semantics can't fork. `--title` is required
    /// non-empty at the parser; the guard here keeps a direct caller's
    /// blank title from CLEARING the tab's name (renameTab's blank = clear
    /// is the popover's affordance, not this verb's).
    private func handleRename(_ request: KookyCLIRequest) -> KookyCLIResponse {
        guard let id = sessionUUID(request) else {
            return refuse("rename needs --tab <session-uuid>")
        }
        guard let title = request.title.flatMap(normalizedTitle) else {
            return refuse("rename needs --title <title>")
        }
        guard let hit = locate(id) else {
            return refuse("no tab with id \(id.uuidString) — run `kooky-cli list`")
        }
        hit.context.store.renameTab(hit.session, to: title)
        return ok(note: "renamed")
    }

    private func handleOpen(
        _ request: KookyCLIRequest,
        isCallerWaiting: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (KookyCLIResponse) -> Void
    ) {
        if request.command != nil, request.agent != nil {
            completion(refuse("-e and --agent are mutually exclusive"))
            return
        }
        // Resolve the template FIRST: a Terminal preset pins its own
        // directory (`extraCwd`), which is what makes `--cwd` optional.
        var launchTemplate: AgentTemplate = .terminal
        if let agentId = request.agent {
            guard let found = lookupTemplate(agentId) else {
                let known = templates().map(\.id).joined(separator: ", ")
                completion(refuse("unknown agent template '\(agentId)' — known templates: \(known)"))
                return
            }
            launchTemplate = found
        }
        // An explicit `--cwd` wins over the preset's own path — same
        // precedence `WorkspaceStore.addTab` applies to `extraCwd`, and the
        // same reason: the caller said where, so honour it. Resolving the
        // preset's path HERE (rather than letting `addTab` do it) is what
        // makes it participate in workspace matching too.
        let explicitCwd = request.cwd.flatMap { $0.isEmpty ? nil : $0 }
        let templateCwd = launchTemplate.extraCwd.map { ($0 as NSString).expandingTildeInPath }
        // No directory named at all is a legitimate request: open a tab
        // wherever the landing workspace already is. Only a directory that
        // WAS named has to be absolute and to exist.
        let cwdPath = explicitCwd ?? templateCwd
        if let cwdPath, !cwdPath.hasPrefix("/") {
            completion(refuse(
                explicitCwd != nil
                    ? "cwd must be an absolute path"
                    : "the Terminal preset '\(launchTemplate.id)' has a relative path (\(cwdPath)) — pass --cwd <dir> instead"
            ))
            return
        }
        // Every path resolution here is off-main, and that includes the
        // WORKSPACE paths, not just the caller's: `canonicalDiskPath` calls
        // `resolvingSymlinksInPath()`, which waits out the mount timeout for
        // a disconnected network volume. Resolving even one inactive
        // workspace on the main actor would freeze the UI *and* HookServer
        // (its accept source runs on the main queue), so `open` would then
        // time out on the caller as well.
        //
        // Snapshot ids + paths here — both Sendable, unlike `Workspace` —
        // and match by id afterwards. A workspace created while this hop is
        // in flight simply isn't in the map, so it can't be matched; it
        // falls through to the placement ladder, which is the right answer
        // for a workspace that didn't exist when the request arrived.
        let deadline = RequestDeadline(Self.asyncVerbDeadline)
        // Blank collapses to nil (`normalizedTitle`) so a scripted
        // `--title "$MAYBE"` with an empty variable opens an untitled tab
        // instead of one titled with whitespace.
        let title = request.title.flatMap(normalizedTitle)
        let noFocus = request.noFocus == true
        // Nothing to stat, nothing to match against: land in the active
        // workspace and let it supply the directory.
        guard let cwdPath else {
            completion(openTab(
                template: launchTemplate,
                cwd: nil,
                canonicalCwd: nil,
                canonicalPaths: [:],
                command: request.command,
                title: title,
                noFocus: noFocus
            ))
            return
        }
        let workspacePaths: [(id: UUID, path: URL)] = windows().flatMap { context in
            context.store.workspaces.compactMap { workspace in
                workspace.sshRemoteHost == nil ? (workspace.id, workspace.diskPath) : nil
            }
        }
        Task { [weak self] in
            let cwd = URL(fileURLWithPath: cwdPath)
            // Two SEPARATE races, because the two resolutions have opposite
            // failure modes. The requested cwd is the point of the call — if
            // it can't be resolved the request fails. The workspace paths
            // only decide whether this tab PILES INTO a workspace already
            // rooted there, so one unrelated workspace sitting on a dead
            // mount must cost the caller that convenience, never the open
            // itself. Sharing one race made a healthy `open --cwd /local`
            // fail after 10s because of a workspace it never mentioned.
            //
            // The timeout is enforced by the race inside `withOffMainTimeout`,
            // not by measuring elapsed time afterwards: a stat stuck on a
            // dead mount never returns, so there is no "afterwards".
            async let cwdResolution = withOffMainTimeout(Self.directoryProbeBudget) {
                (isDirectory(cwd), canonicalDiskPath(cwd).path)
            }
            async let pathResolution = withOffMainTimeout(Self.matchResolutionBudget) {
                var resolved: [UUID: String] = [:]
                for entry in workspacePaths {
                    resolved[entry.id] = canonicalDiskPath(entry.path).path
                }
                return resolved
            }
            let resolution = await cwdResolution
            // Losing this map degrades placement, never the call: every
            // workspace simply stops matching and the placement ladder picks
            // the landing spot instead.
            let canonicalPaths = await pathResolution ?? [:]
            // `guard let self` alone catches neither shutdown nor lateness:
            // the controller is an AppDelegate property that outlives the
            // ⌘Q drain.
            guard let self, !self.isShuttingDown() else {
                completion(.failure("kooky is shutting down"))
                return
            }
            guard let (exists, canonical) = resolution else {
                completion(.failure("checking \(cwdPath) timed out — is it on an unreachable network volume?"))
                return
            }
            // The probes finished in time, but this continuation may still
            // have queued behind a busy main thread until after the caller
            // gave up. Opening a tab now would run `-e` for someone who was
            // already told the request failed.
            guard !deadline.hasExpired else {
                completion(.failure("kooky took too long to answer; nothing was opened"))
                return
            }
            // The scan above can outlast the caller — a ^C or its own
            // timeout. Spawning now would run `-e` for someone who is no
            // longer there to be told, and who may already have retried.
            guard isCallerWaiting() else {
                completion(.failure("the caller stopped waiting; nothing was opened"))
                return
            }
            guard exists else {
                completion(self.refuse("directory does not exist: \(cwdPath)"))
                return
            }
            completion(self.openTab(
                template: launchTemplate,
                cwd: cwd,
                canonicalCwd: canonical,
                canonicalPaths: canonicalPaths,
                command: request.command,
                title: title,
                noFocus: noFocus
            ))
        }
    }

    /// What piling into an already-open workspace is WORTH waiting for.
    /// Resolving a handful of local paths takes microseconds; this budget
    /// only ever expires because a workspace sits on a dead mount, and at
    /// that point the honest trade is to lose the convenience rather than
    /// stall the open behind a directory the caller never mentioned. It is
    /// deliberately far below `asyncVerbDeadline`, which bounds the things
    /// the request actually depends on.
    private static let matchResolutionBudget: Duration = .seconds(2)

    /// One directory probe's budget — strictly under `asyncVerbDeadline` for
    /// the same reason the resume path separates its two: the request
    /// deadline starts first and is read after the probe returns, so equal
    /// budgets guarantee that a probe running its full length reports into
    /// an already-expired request.
    static let directoryProbeBudget: Duration = .seconds(6)

    /// How long an async verb may take before its result is discarded.
    /// Deliberately under the CLI's own 15s reply timeout so kooky always
    /// gives up FIRST — the caller then gets a real answer instead of a
    /// timeout, and nothing lands after it walked away. Same value the
    /// resume pipeline uses.
    static let asyncVerbDeadline: Duration = .seconds(10)

    /// Placement: a local workspace already rooted at this directory wins
    /// (repeat "open in kooky" calls for one project pile into its
    /// workspace); else the active window's active local workspace; else any
    /// local workspace there; else a fresh workspace at the cwd — the
    /// store's shared local-spawn policy, so SSH workspaces can never wrap a
    /// local command in kooky-ssh.
    /// `cwd` / `canonicalCwd` are nil when the caller named no directory —
    /// there is then nothing to match a workspace against, and the landing
    /// workspace supplies the directory itself.
    private func openTab(
        template: AgentTemplate,
        cwd: URL?,
        canonicalCwd: String?,
        canonicalPaths: [UUID: String],
        command: String?,
        title: String?,
        noFocus: Bool
    ) -> KookyCLIResponse {
        let allWindows = windows()
        let landed: (context: WindowContext, workspace: Workspace, session: Session)
        if let canonicalCwd,
           let match = workspaceMatch(in: allWindows, canonicalCwd: canonicalCwd, canonicalPaths: canonicalPaths) {
            let session = match.context.store.addTab(
                in: match.workspace,
                template: template,
                initialCwd: cwd,
                rawLaunchCommand: command,
                customTitle: title,
                activate: !noFocus,
                spawnInBackground: noFocus
            )
            landed = (match.context, match.workspace, session)
        } else {
            let host: WindowContext
            let builtWindow: Bool
            if let existing = allWindows.first(where: { $0.isKey }) ?? allWindows.first {
                host = existing
                builtWindow = false
            } else if noFocus {
                // Zero terminal windows (Settings/About keeping the app
                // alive): the fallback would BUILD one, and addWindow
                // fronts what it builds — a promise --no-focus exists to
                // not break. Refuse before the side effect instead of
                // presenting a "background" tab in a brand-new key window
                // (the close verb's windowBusy precedent: refuse loudly
                // over silently doing something else).
                return refuse("no terminal window to land a background tab in — drop --no-focus or open a kooky window first")
            } else if let fallback = fallbackWindow() {
                host = fallback.context
                builtWindow = fallback.builtWindow
            } else {
                return refuse("kooky is shutting down")
            }
            // One call, one tab: when this has to create the WORKSPACE,
            // `localSpawn` makes its seed tab the launch instead of leaving
            // a blank shell beside it.
            // `handleOpen` already confirmed this directory off-main and
            // refused if it was missing — re-probing here would re-freeze the
            // UI on a slow volume, and its $HOME fallback would quietly run
            // `-e` somewhere the caller never named. (A nil cwd names no
            // directory at all, so there is nothing to confirm or substitute.)
            let spawned = host.store.localSpawn(
                template: template,
                cwd: cwd,
                cwdIsConfirmed: true,
                rawLaunchCommand: command,
                customTitle: title,
                activate: !noFocus,
                spawnInBackground: noFocus
            )
            // A whole WINDOW built for this call arrives with a seed tab of
            // its own, which `localSpawn` lands beside rather than replaces
            // (it reuses that window's workspace instead of making one).
            //
            // KNOWN AND ACCEPTED (product call, 2026-08-21): this does NOT
            // cover a cold start. When kooky wasn't running, the CLI launches
            // it, `restoreWindows()` builds a window before the socket is
            // even up, and that window is indistinguishable from one holding
            // the user's own restored session — so `builtWindow` is false and
            // its seed tab stays. The result is one extra `~` shell on the
            // very first request after a launch, which is the same thing the
            // user would get by opening kooky themselves and then running the
            // command. Telling the two apart would mean marking the launch as
            // CLI-triggered, and getting that wrong deletes a real session —
            // an asymmetric risk not worth taking for one stray tab.
            if builtWindow {
                host.store.discardSeedTab(keeping: spawned.session)
            }
            landed = (host, spawned.workspace, spawned.session)
        }
        // --no-focus is the whole point of the flag: no app activation, no
        // window fronting, and (via `activate: false` above) the tab isn't
        // even its pane's active tab — so a user looking at that workspace
        // keeps seeing what they were seeing. `focus --tab` upgrades later.
        // The note confirms the running-in-background contract (issue #59:
        // the shell spawns through the hidden mount, it does not wait to
        // be shown).
        if noFocus {
            return ok(
                tabId: landed.session.id.uuidString,
                note: "running in the background"
            )
        }
        activateApp()
        landed.context.reveal(landed.session, landed.workspace)
        return ok(tabId: landed.session.id.uuidString)
    }

    private func handleResume(
        _ request: KookyCLIRequest,
        isCallerWaiting: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (KookyCLIResponse) -> Void
    ) {
        // Byte-identical grammar with kooky://resume — validateResume is the
        // deep link's own field gate, so the CLI can't accept an id the URL
        // form would refuse (both end up inside KOOKY_AGENT).
        switch KookyDeepLink.validateResume(
            agentId: request.agent,
            conversationId: request.conversationId,
            cwd: request.cwd
        ) {
        case .invalid(let reason):
            completion(refuse(reason))
        case .resumeSession(let agentId, let conversationId, let cwd):
            // Roster check up front (the pipeline re-checks — it is the deep
            // link's own safety boundary) so a refused agent id fails with
            // the full roster in the message and never activates the app.
            guard AgentSessionScanner.supportedAgentIds.contains(agentId) else {
                let roster = AgentSessionScanner.supportedAgentIds.joined(separator: ", ")
                completion(refuse("unknown agent '\(agentId)' — resumable agents: \(roster)"))
                return
            }
            resume(agentId, conversationId, cwd, isCallerWaiting) { [weak self] outcome in
                guard let self else {
                    completion(.failure("kooky is shutting down"))
                    return
                }
                switch outcome {
                case .revealed:
                    // Activate only on success — a failed script call must
                    // not yank kooky frontmost (the reveal itself already
                    // ordered the window; activation makes it visible).
                    self.activateApp()
                    completion(self.ok(note: "revealed the open conversation tab"))
                case .opened:
                    self.activateApp()
                    completion(self.ok(note: "resumed in a new tab"))
                case .failed(let reason), .dropped(let reason):
                    completion(self.refuse(reason))
                }
            }
        }
    }

    // MARK: - Shared pieces

    private func ok(tabId: String? = nil, note: String? = nil, windows: [KookyCLIWindowInfo]? = nil) -> KookyCLIResponse {
        KookyCLIResponse(ok: true, appVersion: appVersion, tabId: tabId, note: note, windows: windows)
    }

    private func refuse(_ message: String) -> KookyCLIResponse {
        .failure(message, appVersion: appVersion)
    }

    private func sessionUUID(_ request: KookyCLIRequest) -> UUID? {
        request.tab.flatMap(UUID.init(uuidString:))
    }

    /// Exact id first; unique case-insensitive match second, so
    /// `--agent Claude-Code` works the way the resume door's lowercasing
    /// does without letting two case-colliding custom ids match silently.
    private func lookupTemplate(_ id: String) -> AgentTemplate? {
        let roster = templates()
        if let exact = roster.first(where: { $0.id == id }) { return exact }
        let needle = id.lowercased()
        let folded = roster.filter { $0.id.lowercased() == needle }
        return folded.count == 1 ? folded[0] : nil
    }

    private func locate(_ id: UUID) -> (context: WindowContext, workspace: Workspace, session: Session)? {
        for context in windows() {
            for workspace in context.store.workspaces {
                if let pane = workspace.root.pane(containingSessionId: id),
                   let session = pane.tabs.first(where: { $0.id == id }) {
                    return (context, workspace, session)
                }
            }
        }
        return nil
    }

    /// `canonicalPaths` is the off-main resolution done in `handleOpen`;
    /// this only compares strings, so no filesystem call can block the main
    /// actor here. A workspace missing from the map (created mid-flight)
    /// simply doesn't match.
    private func workspaceMatch(
        in windows: [WindowContext],
        canonicalCwd: String,
        canonicalPaths: [UUID: String]
    ) -> (context: WindowContext, workspace: Workspace)? {
        for context in windows {
            if let workspace = context.store.workspaces.first(where: {
                $0.sshRemoteHost == nil && canonicalPaths[$0.id] == canonicalCwd
            }) {
                return (context, workspace)
            }
        }
        return nil
    }

    private func listWindows() -> [KookyCLIWindowInfo] {
        windows().enumerated().map { index, context in
            let store = context.store
            return KookyCLIWindowInfo(
                index: index + 1,
                isKey: context.isKey,
                workspaces: store.workspaces.map { workspace in
                    KookyCLIWorkspaceInfo(
                        id: workspace.id.uuidString,
                        title: workspace.title,
                        path: workspace.diskPath.path,
                        isActive: store.activeWorkspaceId == workspace.id,
                        tabs: workspace.root.allPanes.flatMap { pane in
                            pane.tabs.map { tab in
                                KookyCLITabInfo(
                                    id: tab.id.uuidString,
                                    title: tab.title,
                                    cwd: tab.currentDirectory.path,
                                    isActive: pane.activeTabId == tab.id,
                                    agent: tab.displayAgent.isShell ? "terminal" : tab.displayAgent.id,
                                    agentState: tab.displayAgent.isShell
                                        ? nil
                                        : Self.stateString(AgentMonitor.state(of: tab))
                                )
                            }
                        }
                    )
                }
            )
        }
    }

    /// Wire-stable state words — deliberately NOT `AgentMonitor.State.label`
    /// (that one is localized UI text; `list --json` consumers need values
    /// that don't change with the app language).
    private static func stateString(_ state: AgentMonitor.State) -> String {
        switch state {
        case .attention: return "waiting"
        case .failed: return "failed"
        case .running: return "running"
        case .idle: return "idle"
        }
    }
}
