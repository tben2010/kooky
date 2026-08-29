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
    @State private var branchEditedManually: Bool
    @State private var modelText: String
    @State private var skillText: String

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
        // A branch that still equals the title-derived suggestion keeps
        // following the title; anything else is the user's and stays.
        _branchEditedManually = State(initialValue:
            !card.title.isEmpty && card.branchName != KanbanCard.suggestedBranchName(for: card.title)
        )
        _modelText = State(initialValue: card.model ?? "")
        _skillText = State(initialValue: card.skill ?? "")
    }

    private var agents: [AgentTemplate] {
        AgentTemplate.visibleOrdered(model: KookySettingsModel.shared).filter { !$0.isShell }
    }

    /// The card is launched already (or was): branch and project are
    /// frozen — the worktree on disk carries them.
    private var launchFieldsLocked: Bool {
        draft.worktreePath != nil
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
                    .onChange(of: draft.title) { _, title in
                        guard !branchEditedManually, !launchFieldsLocked else { return }
                        draft.branchName = KanbanCard.suggestedBranchName(for: title)
                    }
            }
            field("requirement") {
                editor($draft.requirement, minHeight: 110)
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
                    TextField(String(localized: "default", bundle: bundle), text: $modelText)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(12))
                        .padding(8)
                        .bracketBorder()
                }
                field("skill") {
                    TextField("/develop", text: $skillText)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(12))
                        .padding(8)
                        .bracketBorder()
                }
            }
            field("branch") {
                TextField("feature/…", text: $draft.branchName)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .padding(8)
                    .bracketBorder()
                    .disabled(launchFieldsLocked)
                    .opacity(launchFieldsLocked ? 0.6 : 1)
                    .onChange(of: draft.branchName) { _, value in
                        if value != KanbanCard.suggestedBranchName(for: draft.title) {
                            branchEditedManually = true
                        }
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
        card.acceptanceCriteria = criteriaText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .map { line in
                // Tolerate pasted markdown checklists / bullets.
                var l = line
                for prefix in ["- [ ] ", "- [x] ", "- ", "* ", "• "] where l.hasPrefix(prefix) {
                    l.removeFirst(prefix.count)
                    break
                }
                return l
            }
            .filter { !$0.isEmpty }
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
