import AppKit
import SwiftUI

/// Brutalist card editor — same visual language as `CreateWorktreeSheet`.
/// Edits a local copy; `save` hands the copy back and the store decides
/// what to take (never the column — drags own that).
struct KanbanCardEditorSheet: View {
    let isNew: Bool
    let save: (KanbanCard) -> Void
    /// nil hides the delete button (new cards have nothing to delete).
    let delete: (() -> Void)?
    let dismiss: () -> Void

    @State private var draft: KanbanCard
    @State private var criteriaText: String
    @State private var modelText: String
    @State private var skillText: String
    /// Discovered off-thread on appear; empty until then (and stays empty
    /// for agents that don't speak slash commands).
    @State private var skills: [KanbanSkill] = []
    /// Model suggestions + configured default for the selected agent,
    /// resolved off-thread whenever the agent changes.
    @State private var modelInfo = KanbanModelSuggestions.Info(suggestions: [], defaultModel: nil)
    /// Branches + worktrees of the card's repo, read off-thread on appear.
    /// nil until loaded (or when the project isn't a git repo).
    @State private var repoInfo: KanbanRepoInfo?
    /// "draft with agent" round-trip state. The proposal never lands in the
    /// fields on its own — the user applies or discards it.
    @State private var isDrafting = false
    @State private var draftError: String?
    @State private var draftProposal: KanbanCardDraft?

    private var bundle: Bundle { .kookyResources }

    init(
        card: KanbanCard,
        isNew: Bool,
        save: @escaping (KanbanCard) -> Void,
        delete: (() -> Void)?,
        dismiss: @escaping () -> Void
    ) {
        self.isNew = isNew
        self.save = save
        self.delete = delete
        self.dismiss = dismiss
        _draft = State(initialValue: card)
        _criteriaText = State(initialValue: card.acceptanceCriteria.joined(separator: "\n"))
        _modelText = State(initialValue: card.model ?? "")
        _skillText = State(initialValue: card.skill ?? "")
    }

    private var agents: [AgentTemplate] {
        AgentTemplate.visibleOrdered(model: KookySettingsModel.shared).filter { !$0.isShell }
    }

    /// The card is launched already (or was): branch and project are
    /// frozen — the worktree on disk (or the running tab) carries them.
    private var launchFieldsLocked: Bool {
        draft.worktreePath != nil || draft.launchedSessionId != nil
    }

    private var featureBranchSuggestion: String {
        KanbanCard.suggestedBranchName(for: draft.title)
    }

    /// One line under the branch field saying what a launch will do.
    private var branchPlanHint: String? {
        guard let repoInfo else { return nil }
        let branch = draft.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return nil }
        switch repoInfo.plan(for: branch) {
        case .inPlace:
            return String(localized: "current branch — the agent works in the repository itself, no worktree", bundle: bundle)
        case .adoptWorktree(let path):
            return String.localizedStringWithFormat(
                String(localized: "already checked out in %@ — the agent works there", bundle: bundle),
                (path.path as NSString).abbreviatingWithTildeInPath
            )
        case .worktreeOnExistingBranch:
            return String(localized: "existing branch — a new worktree checks it out", bundle: bundle)
        case .worktreeOnNewBranch:
            return String.localizedStringWithFormat(
                String(localized: "new branch from %@ — created in a new worktree", bundle: bundle),
                repoInfo.currentBranch ?? "HEAD"
            )
        }
    }

    private var selectedTemplate: AgentTemplate? {
        AgentTemplate.all.first { $0.id == draft.agentId }
    }

    private var modelSuggestions: [String] { modelInfo.suggestions }

    /// "default" or "default (claude-fable-5)" — what a blank field means.
    private var defaultModelLabel: String {
        let base = String(localized: "default", bundle: bundle)
        guard let configured = modelInfo.defaultModel else { return base }
        return "\(base) (\(configured))"
    }

    /// Skills are Claude Code's dialect; other agents keep a plain field.
    private var offersSkillPicker: Bool {
        selectedTemplate?.rosterId == AgentTemplate.claudeCodeID
    }

    /// Menu row that marks the current value — so "none" / "default" read
    /// as a state, not just an action.
    private func choice(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    /// A field with an optional trailing menu of suggestions. The menu
    /// only writes into the text — free text is always allowed.
    private func suggestionField<Content: View>(
        text: Binding<String>,
        placeholder: String,
        disabled: Bool = false,
        @ViewBuilder menu: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .disabled(disabled)
            Menu {
                menu()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.chromeMuted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(8)
        .bracketBorder()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLabel
                .padding(.bottom, 18)
            headline
            subtitle
                .padding(.top, 6)
            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.vertical, 22)
            form
            issues
            HStack(spacing: 10) {
                if let delete {
                    BracketButton("delete") { delete() }
                        .foregroundStyle(Theme.activityFailure)
                }
                Spacer()
                BracketButton("cancel") { dismiss() }
                BracketButton(isNew ? "create" : "save") { submit() }
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.4)
            }
            .padding(.top, 22)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 28)
        .frame(width: 560, alignment: .topLeading)
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        .task {
            let root = draft.projectRoot
            async let scanned = Task.detached(priority: .utility) {
                KanbanSkillCatalog.scan(projectRoot: root)
            }.value
            async let repo = Task.detached(priority: .userInitiated) {
                KanbanRepoInfo.load(projectRoot: root)
            }.value
            let loaded = await repo
            repoInfo = loaded
            // A fresh card starts on the main checkout's branch — "work on
            // main" is the default, a feature branch is the `+` button.
            if draft.branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !launchFieldsLocked {
                draft.branchName = loaded.defaultBranch
            }
            skills = await scanned
        }
        .task(id: draft.agentId) {
            let root = draft.projectRoot
            let template = selectedTemplate
            modelInfo = await Task.detached(priority: .utility) {
                KanbanModelSuggestions.resolve(for: template, projectRoot: root)
            }.value
        }
    }

    // MARK: Sections

    private var statusLabel: some View {
        Text(String(localized: isNew ? "NEW-CARD" : "EDIT-CARD", bundle: bundle))
            .font(Theme.mono(10, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(Theme.chromeMuted.opacity(0.85))
    }

    private var headline: some View {
        Text(draft.title.isEmpty ? String(localized: "Untitled", bundle: bundle) : draft.title)
            .font(Theme.display(20, weight: .medium))
            .foregroundStyle(Theme.chromeForeground)
            .lineLimit(2)
    }

    private var subtitle: some View {
        Text((draft.projectRoot.path as NSString).abbreviatingWithTildeInPath)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.chromeMuted)
            .lineLimit(1)
            .truncationMode(.head)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("title") {
                TextField(String(localized: "Short feature name", bundle: bundle), text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .padding(8)
                    .bracketBorder()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    Text(LocalizedStringKey("requirement"), bundle: bundle)
                        .font(Theme.mono(10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(Theme.chromeMuted.opacity(0.85))
                    Spacer()
                    if isDrafting {
                        ProgressView().controlSize(.mini)
                        Text(String(localized: "asking the agent…", bundle: bundle))
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.chromeMuted)
                    } else {
                        BracketButton("draft with agent") { runDraft() }
                            .disabled(!canDraft)
                            .opacity(canDraft ? 1 : 0.4)
                            .help(draftHelp)
                    }
                }
                editor($draft.requirement, minHeight: 110)
                if let draftError {
                    Text(draftError)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.activityFailure.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            attachmentsSection
            if let draftProposal {
                proposalView(draftProposal)
            }
            field("acceptance-criteria (one per line)") {
                editor($criteriaText, minHeight: 90)
            }
            HStack(alignment: .top, spacing: 14) {
                field("agent") {
                    Picker("", selection: $draft.agentId) {
                        ForEach(agents) { agent in
                            Text(agent.title).tag(agent.id)
                        }
                        if !agents.contains(where: { $0.id == draft.agentId }) {
                            Text(draft.agentId).tag(draft.agentId)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                field("model") {
                    suggestionField(text: $modelText, placeholder: defaultModelLabel) {
                        choice(defaultModelLabel, isSelected: modelText.isEmpty) { modelText = "" }
                        if !modelSuggestions.isEmpty {
                            Divider()
                            ForEach(modelSuggestions, id: \.self) { model in
                                choice(model, isSelected: modelText == model) { modelText = model }
                            }
                        }
                        if selectedTemplate?.modelFlag == nil {
                            Divider()
                            Text(String(localized: "no model flag known for this agent", bundle: bundle))
                        }
                    }
                }
                field("skill") {
                    suggestionField(text: $skillText, placeholder: String(localized: "none", bundle: bundle)) {
                        choice(String(localized: "none", bundle: bundle), isSelected: skillText.isEmpty) { skillText = "" }
                        if offersSkillPicker {
                            ForEach(KanbanSkill.Scope.allCases, id: \.self) { scope in
                                let group = skills.filter { $0.scope == scope }
                                if !group.isEmpty {
                                    Divider()
                                    Section(String(localized: String.LocalizationValue(scope.rawValue), bundle: bundle)) {
                                        ForEach(group) { skill in
                                            let label = skill.description.isEmpty
                                                ? skill.name
                                                : "\(skill.name) — \(singleLine(skill.description).prefix(60))"
                                            choice(label, isSelected: skillText == skill.name || skillText == "/\(skill.name)") {
                                                skillText = skill.name
                                            }
                                        }
                                    }
                                }
                            }
                            if skills.isEmpty {
                                Divider()
                                Text(String(localized: "no skills found", bundle: bundle))
                            }
                        } else {
                            Divider()
                            Text(String(localized: "skills are a Claude Code feature", bundle: bundle))
                        }
                    }
                }
            }
            field("branch") {
                HStack(spacing: 8) {
                    suggestionField(
                        text: $draft.branchName,
                        placeholder: repoInfo?.defaultBranch ?? "main",
                        disabled: launchFieldsLocked
                    ) {
                        if let repoInfo {
                            if let current = repoInfo.currentBranch {
                                choice("\(current) — \(String(localized: "current", bundle: bundle))", isSelected: draft.branchName == current) {
                                    draft.branchName = current
                                }
                                Divider()
                            }
                            ForEach(repoInfo.branches.filter { $0 != repoInfo.currentBranch }, id: \.self) { branch in
                                let worktree = repoInfo.worktreePath(checkingOut: branch)
                                choice(
                                    worktree == nil ? branch : "\(branch) — \(String(localized: "in worktree", bundle: bundle))",
                                    isSelected: draft.branchName == branch
                                ) { draft.branchName = branch }
                            }
                        } else {
                            Text(String(localized: "reading branches…", bundle: bundle))
                        }
                    }
                    .opacity(launchFieldsLocked ? 0.6 : 1)
                    // "+" = a feature branch for this card, `feature/<title-slug>`.
                    // Still plain text afterwards — edit or pick another.
                    BracketButton("+", localizesTitle: false) {
                        draft.branchName = featureBranchSuggestion
                    }
                    .disabled(launchFieldsLocked || featureBranchSuggestion.isEmpty)
                    .opacity(launchFieldsLocked || featureBranchSuggestion.isEmpty ? 0.4 : 1)
                    .help(featureBranchSuggestion.isEmpty
                          ? String(localized: "Enter a title first", bundle: bundle)
                          : String.localizedStringWithFormat(String(localized: "Use feature branch %@", bundle: bundle), featureBranchSuggestion))
                }
                if let branchPlanHint {
                    Text(branchPlanHint)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.chromeMuted.opacity(0.8))
                        .lineLimit(2)
                }
            }
            if let worktree = draft.worktreePath {
                field("worktree") {
                    Text((worktree.path as NSString).abbreviatingWithTildeInPath)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.chromeMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if !draft.events.isEmpty {
                field("history") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(draft.events.suffix(4).reversed()) { event in
                            HStack(spacing: 8) {
                                Text(event.timestamp.formatted(date: .numeric, time: .shortened))
                                    .foregroundStyle(Theme.chromeMuted.opacity(0.6))
                                Text(event.message)
                                    .foregroundStyle(Theme.chromeMuted)
                                    .lineLimit(1)
                            }
                            .font(Theme.mono(10))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var issues: some View {
        let issues = pendingCard.readinessIssues
        if !issues.isEmpty {
            Text(issues.map { String(localized: String.LocalizationValue($0), bundle: bundle) }
                .joined(separator: " · "))
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.activityAttention.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
    }

    // MARK: Draft with agent

    private var canDraft: Bool {
        KanbanCardDrafter.supports(selectedTemplate)
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var draftHelp: String {
        if !KanbanCardDrafter.supports(selectedTemplate) {
            return String(localized: "Drafting needs a Claude Code based agent", bundle: bundle)
        }
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Enter a title first", bundle: bundle)
        }
        return String(localized: "Let the agent write requirement and acceptance criteria from the title and your notes — it reads the repository, changes nothing, and you review before anything is applied", bundle: bundle)
    }

    private func runDraft() {
        guard canDraft, !isDrafting else { return }
        isDrafting = true
        draftError = nil
        draftProposal = nil
        let title = draft.title
        let requirement = draft.requirement
        let criteria = criteriaText.split(whereSeparator: \.isNewline).map(String.init)
        let attachments = draft.attachments
        let root = draft.projectRoot
        let template = selectedTemplate
        let model = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let result = await KanbanCardDrafter.draft(
                title: title,
                requirement: requirement,
                criteria: criteria,
                attachments: attachments,
                projectRoot: root,
                template: template,
                model: model.isEmpty ? nil : model
            )
            isDrafting = false
            switch result {
            case .success(let proposal):
                draftProposal = proposal
            case .failure(let error):
                draftError = error.message
            }
        }
    }

    /// The agent's proposal, previewed next to the user's own text with an
    /// explicit apply — replacing what the user typed is their click, not
    /// the agent's.
    private func proposalView(_ proposal: KanbanCardDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "AGENT-PROPOSAL", bundle: bundle))
                .font(Theme.mono(10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Theme.activityRunning.opacity(0.9))
            Text(proposal.requirement)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.chromeForeground)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(proposal.acceptanceCriteria.enumerated()), id: \.offset) { _, criterion in
                    Text("- [ ] \(criterion)")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.chromeMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                BracketButton("discard") { draftProposal = nil }
                BracketButton("apply") {
                    draft.requirement = proposal.requirement
                    criteriaText = proposal.acceptanceCriteria.joined(separator: "\n")
                    draftProposal = nil
                }
            }
        }
        .padding(12)
        .background(Theme.activityRunning.opacity(0.06))
        .overlay(Rectangle().stroke(Theme.activityRunning.opacity(0.5), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Attachments

    /// Reference files under the requirement. Edits live in `draft` like
    /// every other field — nothing reaches the store before save.
    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text(LocalizedStringKey("attachments"), bundle: bundle)
                    .font(Theme.mono(10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Theme.chromeMuted.opacity(0.85))
                Spacer()
                BracketButton("add files…") { chooseAttachments() }
                    .help(String(localized: "Attach specs, screenshots or mockups — the drafting agent reads them and the launch prompt lists them", bundle: bundle))
            }
            if draft.attachments.isEmpty {
                Text(String(localized: "no attachments", bundle: bundle))
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.6))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(draft.attachments, id: \.self) { path in
                        attachmentRow(path)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attachmentRow(_ path: String) -> some View {
        let missing = !KanbanCard.attachmentExists(path)
        return HStack(spacing: 8) {
            Image(systemName: missing ? "exclamationmark.triangle" : "paperclip")
                .font(.system(size: 10))
                .foregroundStyle(missing ? Theme.activityFailure : Theme.chromeMuted)
            Text(KanbanCard.attachmentFileName(path))
                .font(Theme.mono(11.5))
                .foregroundStyle(missing ? Theme.activityFailure : Theme.chromeForeground)
                .lineLimit(1)
                .truncationMode(.middle)
            if missing {
                Text(String(localized: "missing", bundle: bundle))
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.activityFailure.opacity(0.9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .bracketBorder()
            }
            Spacer(minLength: 0)
            Button {
                draft.attachments.removeAll { $0 == path }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.chromeMuted)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Remove attachment", bundle: bundle))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .bracketBorder()
        .help(missing
              ? String.localizedStringWithFormat(String(localized: "%@ — file not found", bundle: bundle), path)
              : path)
    }

    /// Multi-select file picker, sheet-modal on the editor's window so it
    /// can't land behind the sheet. Picks are appended (deduplicated by
    /// standardized path) to the draft only.
    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose files to attach to this card.", bundle: bundle)
        panel.directoryURL = draft.projectRoot
        let add: () -> Void = {
            for url in panel.urls {
                let path = KanbanCard.attachmentPath(for: url)
                if !draft.attachments.contains(path) {
                    draft.attachments.append(path)
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK else { return }
                add()
            }
        } else if panel.runModal() == .OK {
            add()
        }
    }

    // MARK: Helpers

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(label), bundle: bundle)
                .font(Theme.mono(10, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Theme.chromeMuted.opacity(0.85))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func editor(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(Theme.mono(12))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight, maxHeight: minHeight * 2)
            .bracketBorder()
    }

    /// The draft with the free-text fields folded in — what `save` gets.
    private var pendingCard: KanbanCard {
        var card = draft
        card.acceptanceCriteria = KanbanCard.criteria(fromLines: criteriaText)
        let model = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        card.model = model.isEmpty ? nil : model
        let skill = skillText.trimmingCharacters(in: .whitespacesAndNewlines)
        card.skill = skill.isEmpty ? nil : skill
        card.title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        card.branchName = card.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        return card
    }

    /// Backlog cards may be saved half-finished — that's what Backlog is
    /// for. Only a title is required so the card has a name on the board.
    private var canSubmit: Bool {
        !pendingCard.title.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        save(pendingCard)
    }
}
