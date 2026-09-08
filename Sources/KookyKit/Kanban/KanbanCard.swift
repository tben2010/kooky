import Foundation

/// Board columns in display order. Raw values are the on-disk spelling in
/// `board.json` — rename a case, keep its raw value.
enum KanbanColumn: String, Codable, CaseIterable, Sendable {
    case backlog
    case ready
    case inProgress
    case inReview
    case done

    /// Column heading. English inline is the localization key (the repo
    /// convention — only zh-Hans overrides live in Localizable.strings).
    @MainActor
    var title: String {
        let key: String
        switch self {
        case .backlog: key = "Backlog"
        case .ready: key = "Ready"
        case .inProgress: key = "In Progress"
        case .inReview: key = "In Review"
        case .done: key = "Done"
        }
        return String(localized: String.LocalizationValue(key), bundle: .kookyResources)
    }

    /// Terminal-state flag: a card here is neither editable-by-default nor
    /// launchable — the sidebar equivalent of "archived".
    var isTerminal: Bool { self == .done }
}

/// One line of the card's audit trail: column moves, launches, failures.
/// Kept small on purpose — it's shown in the editor's footer, not a log
/// viewer. Capped by `KanbanCard.eventCap`.
struct KanbanEvent: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var timestamp: Date
    var message: String
}

/// A feature card. Cards are app-wide (one board across every window) and
/// belong to a git repository via `projectRoot` rather than a workspace id:
/// workspace ids are per-window and die with the sidebar entry, the repo
/// path outlives both.
///
/// The `launch*` fields are the runtime correlation to what "In Progress"
/// created — cleared when the card leaves that column so a relaunch starts
/// clean. `worktreePath` deliberately survives: a card moved back to
/// Backlog keeps its worktree, and the next launch adopts it instead of
/// failing on "branch already checked out".
struct KanbanCard: Codable, Equatable, Identifiable, Sendable {
    static let eventCap = 50

    var id = UUID()
    var title: String
    /// Requirement description, Markdown. The agent gets it verbatim.
    var requirement: String
    /// One criterion per element; the editor edits them as lines.
    var acceptanceCriteria: [String]
    var column: KanbanColumn
    /// Repo root (standardized) the card belongs to.
    var projectRoot: URL
    /// `AgentTemplate.id` of the agent that runs the card.
    var agentId: String
    /// Model override handed to the agent as an option (Phase 2 wires the
    /// per-agent flag); nil = the agent's default.
    var model: String?
    /// Slash-command skill prefixed to the prompt (`/develop …`); nil = none.
    var skill: String?
    /// Reference files for the feature (specs, screenshots, mockups) as
    /// absolute paths. Handed to the drafting agent and listed in the
    /// launch prompt; the files themselves stay where the user picked
    /// them. Missing on pre-field board.json files → empty.
    var attachments: [String]
    /// Branch the worktree checks out. Suggested from the title, editable.
    var branchName: String
    /// Pinned at first launch — mirrors `Workspace.worktreePath`.
    var worktreePath: URL?
    var launchedWorkspaceId: UUID?
    var launchedSessionId: UUID?
    /// The most recent launched tab — NOT cleared when the card leaves In
    /// Progress, so an agent-exit alert that lands after the auto-move to
    /// In Review can still find its card. Optional so pre-field board.json
    /// files decode.
    var lastLaunchedSessionId: UUID?
    /// Agent conversation id captured from the launched session so a
    /// relaunch can resume rather than restart (Phase 2).
    var conversationId: String?
    var events: [KanbanEvent]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        requirement: String = "",
        acceptanceCriteria: [String] = [],
        column: KanbanColumn = .backlog,
        projectRoot: URL,
        agentId: String,
        model: String? = nil,
        skill: String? = nil,
        attachments: [String] = [],
        branchName: String? = nil,
        now: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.requirement = requirement
        self.acceptanceCriteria = acceptanceCriteria
        self.column = column
        self.projectRoot = projectRoot.standardizedFileURL
        self.agentId = agentId
        self.model = model
        self.skill = skill
        self.attachments = attachments
        self.branchName = branchName ?? Self.suggestedBranchName(for: title)
        self.events = []
        self.createdAt = now
        self.updatedAt = now
    }

    /// Hand-written so `attachments` (added after the first boards were
    /// written) may be absent; every other key decodes as synthesized.
    /// `encode(to:)` and `CodingKeys` stay compiler-generated.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        requirement = try c.decode(String.self, forKey: .requirement)
        acceptanceCriteria = try c.decode([String].self, forKey: .acceptanceCriteria)
        column = try c.decode(KanbanColumn.self, forKey: .column)
        projectRoot = try c.decode(URL.self, forKey: .projectRoot)
        agentId = try c.decode(String.self, forKey: .agentId)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        skill = try c.decodeIfPresent(String.self, forKey: .skill)
        attachments = try c.decodeIfPresent([String].self, forKey: .attachments) ?? []
        branchName = try c.decode(String.self, forKey: .branchName)
        worktreePath = try c.decodeIfPresent(URL.self, forKey: .worktreePath)
        launchedWorkspaceId = try c.decodeIfPresent(UUID.self, forKey: .launchedWorkspaceId)
        launchedSessionId = try c.decodeIfPresent(UUID.self, forKey: .launchedSessionId)
        lastLaunchedSessionId = try c.decodeIfPresent(UUID.self, forKey: .lastLaunchedSessionId)
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
        events = try c.decode([KanbanEvent].self, forKey: .events)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    // MARK: Derived

    /// `feature/<slug>` from the title — lowercase, ASCII-folded, dashes
    /// for anything git or a shell would trip on. Empty title → empty slug
    /// so the editor's validation (not a silent `feature/`) catches it.
    static func suggestedBranchName(for title: String) -> String {
        let folded = title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))
            .lowercased()
        var slug = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            let isWordChar = (scalar.value >= 0x61 && scalar.value <= 0x7A)   // a-z
                || (scalar.value >= 0x30 && scalar.value <= 0x39)             // 0-9
            if isWordChar {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        guard !slug.isEmpty else { return "" }
        return "feature/\(slug.prefix(48))"
    }

    /// Non-empty criteria only — blank lines in the editor don't count.
    var effectiveCriteria: [String] {
        acceptanceCriteria
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Why this card can't move to Ready (or launch) yet. Empty = ready.
    /// Strings are localization keys like every other user-facing string.
    var readinessIssues: [String] {
        var issues: [String] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("title is empty")
        }
        if requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("requirement is empty")
        }
        if effectiveCriteria.isEmpty {
            issues.append("no acceptance criteria")
        }
        if agentId.isEmpty {
            issues.append("no agent selected")
        }
        if !Self.isValidBranchName(branchName) {
            issues.append("branch name is invalid")
        }
        return issues
    }

    var isReady: Bool { readinessIssues.isEmpty }

    /// A conservative subset of `git check-ref-format --branch`: no
    /// whitespace, no `..`, no control/shell-hostile characters, doesn't
    /// start or end with `/`, `.` or `-`.
    static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 200 else { return false }
        if name.contains("..") || name.contains("@{") || name.hasSuffix(".lock") { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "~^:?*[\\'\"`$;&|<>()"))
        if name.unicodeScalars.contains(where: { forbidden.contains($0) }) { return false }
        let edges = CharacterSet(charactersIn: "/.-")
        if let first = name.unicodeScalars.first, edges.contains(first) { return false }
        if let last = name.unicodeScalars.last, edges.contains(last) { return false }
        return true
    }

    // MARK: Attachments

    /// Test seam for "does this attachment still exist" — the prompt and the
    /// editor both mark files that went away instead of dropping them.
    nonisolated(unsafe) static var attachmentExists: @Sendable (_ path: String) -> Bool = { path in
        FileManager.default.fileExists(atPath: path)
    }

    /// Absolute path for a picked file — `standardizedFileURL` folds `..`
    /// and symlinked `/tmp`-style prefixes so duplicates compare equal.
    static func attachmentPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    static func attachmentFileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Suffix the prompts append to an attachment whose file is gone.
    static let missingAttachmentNote = "MISSING — the file no longer exists at this path; tell the user instead of guessing its content"

    /// One Markdown bullet per attachment, absolute path in backticks,
    /// missing files flagged in place (never silently skipped).
    static func attachmentLines(_ paths: [String]) -> [String] {
        paths.map { path in
            attachmentExists(path)
                ? "- `\(path)`"
                : "- `\(path)` (\(missingAttachmentNote))"
        }
    }

    /// The text the agent is launched with. `workingDirectory` / `branch`
    /// are passed in (not read from self) so the prompt describes the
    /// launch that is actually happening, not a stale pin. `isWorktree`
    /// picks the wording: a card on the main checkout's branch works in the
    /// repo itself.
    func promptText(workingDirectory: URL, branch: String, isWorktree: Bool) -> String {
        var lines: [String] = []
        if let skill = skill?.trimmingCharacters(in: .whitespacesAndNewlines), !skill.isEmpty {
            let slash = skill.hasPrefix("/") ? skill : "/\(skill)"
            lines.append(slash)
        }
        lines.append("# Feature: \(title.trimmingCharacters(in: .whitespacesAndNewlines))")
        lines.append("")
        lines.append("## Requirement")
        lines.append(requirement.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        lines.append("## Acceptance criteria")
        for criterion in effectiveCriteria {
            lines.append("- [ ] \(criterion)")
        }
        if !attachments.isEmpty {
            lines.append("")
            lines.append("## Attachments")
            lines.append("Reference files for this feature (absolute paths). Read them before you start; they are part of the specification.")
            lines.append(contentsOf: Self.attachmentLines(attachments))
        }
        lines.append("")
        lines.append("## Working agreement")
        if isWorktree {
            lines.append("You are working in the git worktree `\(workingDirectory.path)` on branch `\(branch)`.")
            lines.append("Stay inside this worktree. Commit completed steps with clear messages.")
        } else {
            lines.append("You are working in the repository `\(workingDirectory.path)` on branch `\(branch)`.")
            lines.append("Stay on this branch. Commit completed steps with clear messages.")
        }
        lines.append("Do not merge into other branches.")
        lines.append("Progress notes for the human: `kooky-cli card --note \"<text>\" --id \(id.uuidString)`")
        lines.append("When every acceptance criterion is met, run: `kooky-cli card --done --id \(id.uuidString)`")
        return lines.joined(separator: "\n")
    }

    // MARK: Mutation helpers

    mutating func touch(now: Date = Date()) {
        updatedAt = now
    }

    mutating func record(_ message: String, now: Date = Date()) {
        events.append(KanbanEvent(timestamp: now, message: message))
        if events.count > Self.eventCap {
            events.removeFirst(events.count - Self.eventCap)
        }
        touch(now: now)
    }

    /// Forget the launched tab/workspace but keep the worktree pin — see
    /// the type doc for why.
    mutating func clearLaunchLinks() {
        launchedWorkspaceId = nil
        launchedSessionId = nil
    }
}
