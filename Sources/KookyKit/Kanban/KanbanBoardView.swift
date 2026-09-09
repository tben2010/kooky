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
    /// Archived card opened for reading — a separate slot from
    /// `editingCard` so the sheet knows it's read-only.
    @State private var viewingArchivedCard: KanbanCard?
    @State private var isCreatingCard = false
    /// "show archive": archived cards of the current project filter appear
    /// read-only under Done. Per window, not persisted — the archive is
    /// something you look into, not a mode you live in.
    @State private var showArchive = false
    @State private var confirmArchiveAll = false
    @State private var dropTargetColumn: KanbanColumn?
    @State private var notice: Notice?
    @State private var noticeDismissal: Task<Void, Never>?
    @State private var launchingCardIds: Set<UUID> = []
    /// Offset/extent of the narrow layout's horizontal scroller, for the
    /// board's own always-visible indicator.
    @State private var hScroll = HorizontalScrollModel()

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
        .onAppear { consumePendingNewCard() }
        .onChange(of: store.pendingNewCardProjectRoot?.path) { _, _ in consumePendingNewCard() }
        .sheet(item: $editingCard) { card in
            KanbanCardEditorSheet(
                card: card,
                isNew: false,
                save: { edited in board.update(edited); editingCard = nil },
                delete: { board.remove(id: card.id); editingCard = nil },
                archive: card.column == .done ? { archive(card.id); editingCard = nil } : nil,
                dismiss: { editingCard = nil }
            )
        }
        .sheet(item: $viewingArchivedCard) { card in
            KanbanCardEditorSheet(
                card: card,
                isNew: false,
                isReadOnly: true,
                save: { _ in },
                delete: nil,
                restore: { unarchive(card.id); viewingArchivedCard = nil },
                dismiss: { viewingArchivedCard = nil }
            )
        }
        .confirmationDialog(
            String.localizedStringWithFormat(
                String(localized: "Archive %d Done cards?", bundle: bundle),
                doneCardsInFilter.count
            ),
            isPresented: $confirmArchiveAll,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Archive", bundle: bundle)) { performArchiveAll() }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: {
            Text(String(localized: "They leave the board and keep their history in the archive. \"show archive\" lists them; a card can be restored to Done from there.", bundle: bundle))
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
            BracketButton(showArchive ? "hide archive" : "show archive") {
                withAnimation(Theme.chromeTransition) { showArchive.toggle() }
            }
            .help(String.localizedStringWithFormat(
                String(localized: "%d archived cards — shown read-only under Done", bundle: bundle),
                board.archived.count
            ))
            // Split ↔ full: the terminal beside the board is the real pane
            // host, so "watch the agent" is just "activate its tab".
            BracketButton(store.mainContent == .kanbanSplit ? "hide terminal" : "show terminal") {
                withAnimation(Theme.chromeTransition) {
                    store.setMainContent(store.mainContent == .kanbanSplit ? .kanban : .kanbanSplit)
                }
            }
            .help(String(localized: "Show the live terminal next to the board", bundle: bundle))
            BracketButton("close") {
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
            Label(String(localized: "Filter cards by project", bundle: bundle), systemImage: "chevron.down")
                .labelStyle(.iconOnly)
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
        var roots = board.projectRoots(includingArchived: showArchive)
        if let activeProjectRoot, !roots.contains(where: { $0.path == activeProjectRoot.path }) {
            roots.insert(activeProjectRoot, at: 0)
        }
        return roots.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private var canCreateCard: Bool {
        (selectedProject ?? activeProjectRoot) != nil
    }

    /// Done cards "archive all" would take — the current project filter's.
    private var doneCardsInFilter: [KanbanCard] {
        board.cards(in: .done, project: selectedProject)
    }

    /// Newest first: the card you just archived is the one you're most
    /// likely looking for.
    private var archivedCardsInFilter: [KanbanCard] {
        board.archivedCards(project: selectedProject).reversed()
    }

    // MARK: Columns

    private static let minColumnWidth: CGFloat = 240
    private static let scrollColumnWidth: CGFloat = 260
    /// Five fixed columns + hairlines + the row's horizontal padding.
    private static var scrollContentWidth: CGFloat {
        let count = CGFloat(KanbanColumn.allCases.count)
        return count * scrollColumnWidth + (count - 1) + 24
    }

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
                // Narrow (split layout): fixed-width columns behind an
                // always-visible horizontal scroller — SwiftUI's own
                // indicator follows the system's auto-hide setting, which
                // leaves no hint that Done exists off-screen.
                HorizontalScrollHost(contentWidth: Self.scrollContentWidth, model: hScroll) {
                    columnRow(width: Self.scrollColumnWidth)
                }
                .overlay(alignment: .bottom) {
                    KanbanScrollIndicator(model: hScroll)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
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
                if column == .done, !cards.isEmpty {
                    BracketButton("archive all") { archiveAllDone() }
                        .help(String(localized: "Archive every Done card of the current project filter", bundle: bundle))
                }
            }
            .padding(.horizontal, 12)
            // Fixed height so Done's "archive all" button (taller than the
            // 10pt heading) doesn't push that column's cards below the rest.
            .frame(height: 40)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(cards) { card in
                        KanbanCardView(
                            card: card,
                            live: liveStatus(for: card),
                            isLaunching: launchingCardIds.contains(card.id),
                            onOpen: { editingCard = card },
                            onWatch: { watch(card) },
                            onReveal: { reveal(card) },
                            onRelaunch: { relaunch(card) },
                            onReopen: { reopen(card) },
                            onMove: { target in move(card.id, to: target) },
                            onDelete: { board.remove(id: card.id) },
                            onArchive: column == .done ? { archive(card.id) } : nil
                        )
                        .draggable(card.id.uuidString)
                    }
                    if column == .done, showArchive {
                        archiveSection
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

    /// Read-only tail of the Done column while "show archive" is on. The
    /// cards aren't draggable and open in a read-only editor; the only way
    /// out is "restore", which puts the card back above this section.
    private var archiveSection: some View {
        let archivedCards = archivedCardsInFilter
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(String(localized: "ARCHIVE", bundle: bundle))
                    .font(Theme.mono(10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Theme.chromeMuted.opacity(0.9))
                Text("\(archivedCards.count)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.6))
                Spacer()
            }
            .padding(.top, 10)
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            if archivedCards.isEmpty {
                Text(String(localized: "nothing archived for this filter", bundle: bundle))
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.7))
                    .padding(.vertical, 4)
            }
            ForEach(archivedCards) { card in
                KanbanCardView(
                    card: card,
                    live: nil,
                    isLaunching: false,
                    onOpen: { viewingArchivedCard = card },
                    onWatch: {},
                    onReveal: {},
                    onRelaunch: {},
                    onReopen: {},
                    onMove: { _ in },
                    onDelete: {},
                    isArchived: true,
                    onUnarchive: { unarchive(card.id) }
                )
            }
        }
    }

    // MARK: Actions

    private func archive(_ id: UUID) {
        guard let card = board.card(id: id), board.archive(id: id) else { return }
        show(Notice(
            text: String.localizedStringWithFormat(String(localized: "Archived “%@”", bundle: bundle), card.title),
            tone: .info
        ))
    }

    private func unarchive(_ id: UUID) {
        guard let card = board.archivedCard(id: id), board.unarchive(id: id) else { return }
        show(Notice(
            text: String.localizedStringWithFormat(String(localized: "Restored “%@” to Done", bundle: bundle), card.title),
            tone: .info
        ))
    }

    /// One card goes straight away; two or more ask first — "archive all"
    /// sits next to a column header and a stray click must not empty it.
    private func archiveAllDone() {
        let count = doneCardsInFilter.count
        guard count > 0 else { return }
        if count >= 2 {
            confirmArchiveAll = true
        } else {
            performArchiveAll()
        }
    }

    private func performArchiveAll() {
        let count = board.archiveAllDone(project: selectedProject)
        show(Notice(
            text: String.localizedStringWithFormat(String(localized: "Archived %d cards", bundle: bundle), count),
            tone: .info
        ))
    }

    private func move(_ id: UUID, to column: KanbanColumn) {
        if let card = board.card(id: id), card.column == .inProgress {
            KanbanLaunchCoordinator.syncConversationId(card: card, board: board, store: store)
        }
        switch board.move(id, to: column) {
        case .moved:
            if column == .done { offerWorktreeCleanup(id) }
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

    /// In Progress card whose tab is gone (restart, closed tab): start the
    /// agent again in place — resuming the captured conversation if any.
    private func relaunch(_ card: KanbanCard) {
        launchingCardIds.insert(card.id)
        Task { @MainActor in
            let failure = await KanbanLaunchCoordinator.launch(cardId: card.id, board: board, store: store)
            launchingCardIds.remove(card.id)
            if let failure { show(Notice(text: failure, tone: .failure)) }
        }
    }

    /// Sidebar right-click parked a repo root on the store: open the card
    /// editor for it. Consumed here (not in the sidebar) so the flow works
    /// whether the board was already up or is appearing right now.
    private func consumePendingNewCard() {
        guard let root = store.pendingNewCardProjectRoot else { return }
        store.pendingNewCardProjectRoot = nil
        selectedProject = root
        userPickedProject = true
        editingCard = nil
        isCreatingCard = true
    }

    /// A card just landed in Done and owns a worktree. Its sidebar entry
    /// (when there is one) goes through the existing close flow — the same
    /// confirm sheet with the "also delete worktree directory and branch"
    /// checkbox, so removal keeps its one implementation and its safety
    /// (`git branch -d` only deletes merged branches). A worktree that is
    /// only on disk gets a notice instead of silent deletion.
    private func offerWorktreeCleanup(_ id: UUID) {
        guard let card = board.card(id: id), let worktree = card.worktreePath else { return }
        let key = worktree.standardizedFileURL.path
        if let workspace = store.workspaces.first(where: { $0.worktreePath?.standardizedFileURL.path == key }) {
            // The confirm sheet lives in the sidebar — reveal it if hidden,
            // the same courtesy the command palette's worktree route pays.
            if store.sidebarMode == .hidden {
                withAnimation(Theme.chromeTransition) { store.setSidebarMode(.full) }
            }
            store.requestCloseWorkspace(workspace)
        } else if FileManager.default.fileExists(atPath: worktree.path) {
            show(Notice(
                text: String.localizedStringWithFormat(
                    String(localized: "worktree %@ stays on disk — adopt it via Create Worktree to remove it", bundle: bundle),
                    worktree.lastPathComponent
                ),
                tone: .info
            ))
        }
    }

    /// The card's tab is gone but its conversation is on disk: resume it
    /// in a new tab (kooky's own resume path), link the tab to the card,
    /// and show it beside the board.
    private func reopen(_ card: KanbanCard) {
        guard let conversationId = card.conversationId,
              let template = AgentTemplate.all.first(where: { $0.id == card.agentId }) else { return }
        let cwd = card.worktreePath ?? card.projectRoot
        switch store.resumeAgentSession(agentId: template.rosterId, conversationId: conversationId, cwd: cwd) {
        case .success(let session):
            board.linkReopenedSession(id: card.id, sessionId: session.id)
            withAnimation(Theme.chromeTransition) {
                if store.mainContent != .kanbanSplit { store.setMainContent(.kanbanSplit) }
            }
        case .failure(let refusal):
            show(Notice(text: refusal.message(agentId: card.agentId, conversationId: conversationId), tone: .failure))
        }
    }

    private func reveal(_ card: KanbanCard) {
        guard let sessionId = liveSessionId(for: card) else { return }
        board.revealSession(sessionId)
    }

    /// The tab a card is (or was last) running in — `launchedSessionId` is
    /// dropped when the card leaves In Progress, but the terminal usually
    /// outlives that move, and the card must keep pointing at it.
    private func liveSessionId(for card: KanbanCard) -> UUID? {
        card.launchedSessionId ?? card.lastLaunchedSessionId
    }

    private func liveStatus(for card: KanbanCard) -> KanbanLiveStatus? {
        guard let sessionId = liveSessionId(for: card),
              let hit = store.locateSession(sessionId) else { return nil }
        let watched = hit.store === store
            && store.activeWorkspaceId == hit.workspace.id
            && hit.workspace.activeSession?.id == sessionId
            && store.mainContent == .kanbanSplit
        return KanbanLiveStatus(
            state: AgentMonitor.state(of: hit.session),
            tabTitle: singleLine(hit.session.title),
            isWatched: watched
        )
    }

    /// Single click on a launched card. Same window: switch the board to
    /// split (if needed) and make the card's tab the active one beside it.
    /// Another window: hand off to the app-level reveal.
    private func watch(_ card: KanbanCard) {
        guard let sessionId = liveSessionId(for: card),
              let hit = store.locateSession(sessionId) else { return }
        guard hit.store === store else {
            board.revealSession(sessionId)
            return
        }
        withAnimation(Theme.chromeTransition) {
            if store.mainContent != .kanbanSplit { store.setMainContent(.kanbanSplit) }
        }
        store.activateWorkspace(hit.workspace)
        store.activateTab(hit.session, in: hit.workspace)
    }

    private func show(_ new: Notice) {
        noticeDismissal?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { notice = new }
        noticeDismissal = Task { @MainActor in
            try? await Task.sleep(for: .seconds(new.tone == .failure ? 8 : 4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { notice = nil }
        }
    }

    private func newCardDraft() -> KanbanCard {
        let root = selectedProject ?? activeProjectRoot ?? URL(fileURLWithPath: NSHomeDirectory())
        let defaultAgent = AgentTemplate.defaultLaunchTemplate(model: KookySettingsModel.shared)
            ?? AgentTemplate.claudeCode
        // Branch stays empty here: the editor fills in the repo's current
        // branch once it has read git (off-thread) — a card is "work on
        // main" by default, a feature branch is one click away.
        return KanbanCard(projectRoot: root, agentId: defaultAgent.isShell ? AgentTemplate.claudeCodeID : defaultAgent.id, branchName: "")
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

/// Live geometry of the narrow layout's horizontal scroll view — what the
/// board's own indicator draws from, and the handle it scrolls through.
@MainActor
@Observable
final class HorizontalScrollModel {
    var offset: CGFloat = 0
    var visibleWidth: CGFloat = 0
    var contentWidth: CGFloat = 0
    @ObservationIgnored weak var scrollView: NSScrollView?

    var maxOffset: CGFloat { max(0, contentWidth - visibleWidth) }
    var isScrollable: Bool { maxOffset > 1 }

    func scroll(to x: CGFloat) {
        guard let scrollView else { return }
        let clamped = min(max(0, x), maxOffset)
        scrollView.contentView.scroll(to: NSPoint(x: clamped, y: scrollView.contentView.bounds.origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// `NSScrollView` hosting a SwiftUI row of fixed total width, scrollers
/// off — the board draws its own indicator (`KanbanScrollIndicator`), which
/// unlike the system's stays visible and matches the chrome. The document
/// view's height follows the scroll view's content area so the columns
/// fill the board vertically.
private struct HorizontalScrollHost<Content: View>: NSViewRepresentable {
    let contentWidth: CGFloat
    let model: HorizontalScrollModel
    @ViewBuilder let content: () -> Content

    final class ScrollView: NSScrollView {
        var contentWidth: CGFloat = 0
        override func tile() {
            super.tile()
            guard let document = documentView else { return }
            let size = NSSize(width: max(contentWidth, contentSize.width), height: contentSize.height)
            if document.frame.size != size { document.setFrameSize(size) }
        }
    }

    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit { observer.map(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ScrollView {
        let scroll = ScrollView()
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .none
        scroll.contentWidth = contentWidth
        let hosting = NSHostingView(rootView: content())
        hosting.autoresizingMask = []
        scroll.documentView = hosting
        scroll.contentView.postsBoundsChangedNotifications = true
        let model = model
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak scroll] _ in
            MainActor.assumeIsolated {
                guard let scroll else { return }
                model.offset = scroll.contentView.bounds.origin.x
                model.visibleWidth = scroll.contentSize.width
                model.contentWidth = scroll.documentView?.frame.width ?? 0
            }
        }
        model.scrollView = scroll
        return scroll
    }

    func updateNSView(_ scroll: ScrollView, context: Context) {
        scroll.contentWidth = contentWidth
        (scroll.documentView as? NSHostingView<Content>)?.rootView = content()
        scroll.tile()
        let model = model
        // Deferred one tick: observable writes during `updateNSView` would
        // re-enter SwiftUI's update.
        Task { @MainActor in
            model.offset = scroll.contentView.bounds.origin.x
            model.visibleWidth = scroll.contentSize.width
            model.contentWidth = scroll.documentView?.frame.width ?? 0
        }
    }
}

/// Brutalist horizontal scroll indicator: hairline track, muted knob,
/// draggable. Always drawn while the content overflows — the whole point
/// is that Done stays discoverable when the board sits beside a terminal.
private struct KanbanScrollIndicator: View {
    let model: HorizontalScrollModel
    @State private var dragStartOffset: CGFloat?

    private static let height: CGFloat = 8
    private static let minKnob: CGFloat = 40

    var body: some View {
        GeometryReader { proxy in
            let track = proxy.size.width
            let knob = knobWidth(track: track)
            let x = knobX(track: track, knob: knob)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.chromeHairline)
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
                Rectangle()
                    .fill(Theme.chromeMuted.opacity(0.7))
                    .frame(width: knob, height: Self.height)
                    .offset(x: x)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartOffset == nil {
                            // Click outside the knob jumps there; a drag then
                            // continues from that position.
                            let start = value.startLocation.x
                            if start < x || start > x + knob {
                                model.scroll(to: (start - knob / 2) / max(1, track - knob) * model.maxOffset)
                            }
                            dragStartOffset = model.offset
                        }
                        guard let base = dragStartOffset else { return }
                        let ratio = model.maxOffset / max(1, track - knob)
                        model.scroll(to: base + value.translation.width * ratio)
                    }
                    .onEnded { _ in dragStartOffset = nil }
            )
        }
        .frame(height: Self.height)
        .opacity(model.isScrollable ? 1 : 0)
        .allowsHitTesting(model.isScrollable)
    }

    private func knobWidth(track: CGFloat) -> CGFloat {
        guard model.contentWidth > 0 else { return track }
        return max(Self.minKnob, min(track, track * model.visibleWidth / model.contentWidth))
    }

    private func knobX(track: CGFloat, knob: CGFloat) -> CGFloat {
        guard model.maxOffset > 0 else { return 0 }
        return (track - knob) * min(1, max(0, model.offset / model.maxOffset))
    }
}
