import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The board that overlays the pane tree when `store.mainContent == .kanban`.
/// Cards come from the app-wide `KanbanStore`; the window's `WorkspaceStore`
/// supplies the active project (for the default filter), the launch target
/// and live agent state for In Progress cards.
struct KanbanBoardView: View {
    @Bindable var store: WorkspaceStore
    var board: KanbanStore = .shared

    /// nil = every project. Follows the active workspace until the user
    /// picks explicitly; `userPickedProject` freezes it.
    @State private var selectedProject: URL?
    @State private var userPickedProject = false
    /// Repo root of the active workspace, resolved off-thread — nil while
    /// resolving or when the workspace isn't inside a git repo.
    @State private var activeProjectRoot: URL?
    @State private var activeProjectResolved = false
    @State private var editingCard: KanbanCard?
    @State private var isCreatingCard = false
    @State private var dropTargetColumn: KanbanColumn?
    @State private var notice: Notice?
    @State private var noticeDismissal: Task<Void, Never>?
    @State private var launchingCardIds: Set<UUID> = []

    private struct Notice: Equatable {
        enum Tone { case info, failure }
        var text: String
        var tone: Tone
    }

    private var bundle: Bundle { .kookyResources }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Rectangle().fill(Theme.chromeSeparator).frame(height: 1)
            columns
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.chromeBackground)
        .task(id: store.activeWorkspaceId) { await resolveActiveProject() }
        .sheet(item: $editingCard) { card in
            KanbanCardEditorSheet(
                card: card,
                isNew: false,
                save: { edited in board.update(edited); editingCard = nil },
                delete: { board.remove(id: card.id); editingCard = nil },
                dismiss: { editingCard = nil }
            )
        }
        .sheet(isPresented: $isCreatingCard) {
            KanbanCardEditorSheet(
                card: newCardDraft(),
                isNew: true,
                save: { draft in board.add(draft); isCreatingCard = false },
                delete: nil,
                dismiss: { isCreatingCard = false }
            )
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "KANBAN", bundle: bundle))
                    .font(Theme.mono(10, weight: .medium))
                    .tracking(1.6)
                    .foregroundStyle(Theme.chromeMuted.opacity(0.85))
                Text(projectTitle)
                    .font(Theme.display(18, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
                    .lineLimit(1)
            }
            projectPicker
            Spacer(minLength: 12)
            if let notice {
                Text(notice.text)
                    .font(Theme.mono(11))
                    .foregroundStyle(notice.tone == .failure ? Theme.activityFailure : Theme.chromeMuted)
                    .lineLimit(2)
                    .frame(maxWidth: 420, alignment: .trailing)
                    .transition(.opacity)
            }
            BracketButton("new card") { isCreatingCard = true }
                .disabled(!canCreateCard)
                .opacity(canCreateCard ? 1 : 0.4)
                .help(canCreateCard
                      ? String(localized: "Add a card to this project", bundle: bundle)
                      : String(localized: "Open a git repository as a workspace first", bundle: bundle))
            BracketButton("terminals") {
                withAnimation(Theme.chromeTransition) { store.setMainContent(.terminals) }
            }
        }
    }

    private var projectTitle: String {
        if let selectedProject { return selectedProject.lastPathComponent }
        return String(localized: "All projects", bundle: bundle)
    }

    private var projectPicker: some View {
        Menu {
            Button(String(localized: "All projects", bundle: bundle)) {
                selectedProject = nil
                userPickedProject = true
            }
            Divider()
            ForEach(knownProjects, id: \.path) { root in
                Button {
                    selectedProject = root
                    userPickedProject = true
                } label: {
                    Label(root.lastPathComponent, systemImage: root == selectedProject ? "checkmark" : "folder")
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.chromeMuted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Filter cards by project", bundle: bundle))
    }

    /// Every project a card belongs to plus the active workspace's — so a
    /// fresh repo without cards is still pickable for its first card.
    private var knownProjects: [URL] {
        var roots = board.projectRoots
        if let activeProjectRoot, !roots.contains(where: { $0.path == activeProjectRoot.path }) {
            roots.insert(activeProjectRoot, at: 0)
        }
        return roots.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private var canCreateCard: Bool {
        (selectedProject ?? activeProjectRoot) != nil
    }

    // MARK: Columns

    private static let minColumnWidth: CGFloat = 240
    private static let scrollColumnWidth: CGFloat = 260

    /// Five columns share the width when it's there; below the minimum
    /// they take a fixed width and the row scrolls sideways instead of
    /// squeezing card text into slivers.
    private var columns: some View {
        GeometryReader { proxy in
            let count = CGFloat(KanbanColumn.allCases.count)
            let fits = proxy.size.width >= count * Self.minColumnWidth + 24
            if fits {
                columnRow(width: nil)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            } else {
                ScrollView(.horizontal) {
                    columnRow(width: Self.scrollColumnWidth)
                        .frame(height: proxy.size.height, alignment: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func columnRow(width: CGFloat?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(KanbanColumn.allCases, id: \.self) { column in
                columnView(column)
                    .frame(width: width)
                    .frame(maxWidth: width == nil ? .infinity : nil)
                if column != KanbanColumn.allCases.last {
                    Rectangle().fill(Theme.chromeHairline).frame(width: 1)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func columnView(_ column: KanbanColumn) -> some View {
        let cards = board.cards(in: column, project: selectedProject)
        let isTarget = dropTargetColumn == column
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(column.title.uppercased())
                    .font(Theme.mono(10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Theme.chromeMuted.opacity(0.9))
                Text("\(cards.count)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.6))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(cards) { card in
                        KanbanCardView(
                            card: card,
                            status: liveStatus(for: card),
                            isLaunching: launchingCardIds.contains(card.id),
                            onOpen: { editingCard = card },
                            onReveal: { reveal(card) },
                            onMove: { target in move(card.id, to: target) },
                            onDelete: { board.remove(id: card.id) }
                        )
                        .draggable(card.id.uuidString)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(isTarget ? Theme.chromeHover : Color.clear)
        .dropDestination(for: String.self) { items, _ in
            dropTargetColumn = nil
            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
            move(id, to: column)
            return true
        } isTargeted: { targeted in
            dropTargetColumn = targeted ? column : (dropTargetColumn == column ? nil : dropTargetColumn)
        }
    }

    // MARK: Actions

    private func move(_ id: UUID, to column: KanbanColumn) {
        switch board.move(id, to: column) {
        case .moved:
            break
        case .rejected(let reasons):
            let joined = reasons
                .map { String(localized: String.LocalizationValue($0), bundle: bundle) }
                .joined(separator: " · ")
            show(Notice(text: joined, tone: .failure))
        case .needsLaunch:
            launchingCardIds.insert(id)
            Task { @MainActor in
                let failure = await KanbanLaunchCoordinator.launch(cardId: id, board: board, store: store)
                launchingCardIds.remove(id)
                if let failure {
                    show(Notice(text: failure, tone: .failure))
                } else if let card = board.card(id: id) {
                    show(Notice(
                        text: String.localizedStringWithFormat(
                            String(localized: "Started %@ on %@", bundle: bundle),
                            card.agentId, card.branchName
                        ),
                        tone: .info
                    ))
                }
            }
        }
    }

    private func reveal(_ card: KanbanCard) {
        guard let sessionId = card.launchedSessionId else { return }
        board.revealSession(sessionId)
    }

    private func liveStatus(for card: KanbanCard) -> AgentMonitor.State? {
        guard let sessionId = card.launchedSessionId,
              let hit = store.locateSession(sessionId) else { return nil }
        return AgentMonitor.state(of: hit.session)
    }

    private func show(_ new: Notice) {
        noticeDismissal?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { notice = new }
        noticeDismissal = Task { @MainActor in
            try? await Task.sleep(nanoseconds: (new.tone == .failure ? 8 : 4) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { notice = nil }
        }
    }

    private func newCardDraft() -> KanbanCard {
        let root = selectedProject ?? activeProjectRoot ?? URL(fileURLWithPath: NSHomeDirectory())
        let defaultAgent = AgentTemplate.defaultLaunchTemplate(model: KookySettingsModel.shared)
            ?? AgentTemplate.claudeCode
        return KanbanCard(projectRoot: root, agentId: defaultAgent.isShell ? AgentTemplate.claudeCodeID : defaultAgent.id)
    }

    private func resolveActiveProject() async {
        activeProjectResolved = false
        guard let workspace = store.active else {
            activeProjectRoot = nil
            return
        }
        let root = await KanbanLaunchCoordinator.projectRoot(for: workspace, in: store)
        activeProjectRoot = root
        activeProjectResolved = true
        if !userPickedProject, let root {
            selectedProject = root
        }
    }
}
