import SwiftUI

/// Compact card in a board column: title, agent, branch, live state. The
/// whole card is the drag handle; double-click opens the editor.
struct KanbanCardView: View {
    let card: KanbanCard
    /// Live agent state when the card's launched tab is still open; nil
    /// when nothing is running for it.
    let status: AgentMonitor.State?
    let isLaunching: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onMove: (KanbanColumn) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var bundle: Bundle { .kookyResources }

    private var agent: AgentTemplate? {
        AgentTemplate.all.first { $0.id == card.agentId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(card.title.isEmpty ? String(localized: "Untitled", bundle: bundle) : card.title)
                    .font(Theme.display(13, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                statusDot
            }
            if !card.requirement.isEmpty {
                Text(singleLine(card.requirement))
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.chromeMuted)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                if let agent {
                    AgentIconView(asset: agent.iconAsset, fallbackSymbol: agent.symbol, size: 14)
                    Text(agent.title)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.chromeMuted)
                        .lineLimit(1)
                } else {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.activityFailure)
                    Text(card.agentId)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.activityFailure)
                }
                if let model = card.model, !model.isEmpty {
                    Text(model)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.chromeMuted.opacity(0.8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .bracketBorder()
                }
                Spacer(minLength: 0)
                Text("\(card.effectiveCriteria.count) AC")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.7))
            }
            if card.column != .backlog || !card.branchName.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(card.branchName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(Theme.mono(10))
                .foregroundStyle(Theme.chromeMuted.opacity(0.8))
            }
            if !card.isReady, card.column == .backlog {
                Text(card.readinessIssues
                    .map { String(localized: String.LocalizationValue($0), bundle: bundle) }
                    .joined(separator: " · "))
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.activityAttention.opacity(0.9))
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Theme.chromeHover : Theme.chromeActive.opacity(0.35))
        .bracketBorder()
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .contextMenu { contextMenu }
        .help(card.launchedSessionId != nil
              ? String(localized: "Double-click to edit · right-click to jump to the agent tab", bundle: bundle)
              : String(localized: "Double-click to edit", bundle: bundle))
    }

    @ViewBuilder
    private var statusDot: some View {
        if isLaunching {
            ProgressView()
                .controlSize(.mini)
        } else if let status {
            Circle()
                .fill(color(for: status))
                .frame(width: 8, height: 8)
                .help(status.label)
        } else if card.column == .inProgress {
            // Card says running, but no live tab backs it (app relaunch,
            // tab closed): show a hollow dot so the gap is visible.
            Circle()
                .stroke(Theme.chromeMuted, lineWidth: 1)
                .frame(width: 8, height: 8)
                .help(String(localized: "no live agent tab", bundle: bundle))
        }
    }

    private func color(for state: AgentMonitor.State) -> Color {
        switch state {
        case .attention: return Theme.activityAttention
        case .failed: return Theme.activityFailure
        case .running: return Theme.activityRunning
        case .idle: return Theme.chromeMuted
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(String(localized: "Edit…", bundle: bundle)) { onOpen() }
        if card.launchedSessionId != nil {
            Button(String(localized: "Show Agent Tab", bundle: bundle)) { onReveal() }
        }
        Divider()
        Menu(String(localized: "Move to", bundle: bundle)) {
            ForEach(KanbanColumn.allCases, id: \.self) { column in
                Button(column.title) { onMove(column) }
                    .disabled(column == card.column)
            }
        }
        Divider()
        Button(String(localized: "Delete Card", bundle: bundle), role: .destructive) { onDelete() }
    }
}
