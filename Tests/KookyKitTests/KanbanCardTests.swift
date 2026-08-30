import XCTest
@testable import KookyKit

final class KanbanCardTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/kanban-project")

    // MARK: - Branch suggestion

    func testSuggestedBranchNameSlugsTitle() {
        XCTAssertEqual(KanbanCard.suggestedBranchName(for: "Add Kanban board"), "feature/add-kanban-board")
        XCTAssertEqual(KanbanCard.suggestedBranchName(for: "  Löschen: Ünïcode/Test!! "), "feature/loschen-unicode-test")
        XCTAssertEqual(KanbanCard.suggestedBranchName(for: "v2.0 -- release"), "feature/v2-0-release")
    }

    func testSuggestedBranchNameEmptyForEmptyTitle() {
        XCTAssertEqual(KanbanCard.suggestedBranchName(for: ""), "")
        XCTAssertEqual(KanbanCard.suggestedBranchName(for: "!!!"), "")
    }

    func testSuggestedBranchNameCapsLength() {
        let long = String(repeating: "abcde ", count: 30)
        let name = KanbanCard.suggestedBranchName(for: long)
        XCTAssertTrue(name.hasPrefix("feature/"))
        XCTAssertLessThanOrEqual(name.count, "feature/".count + 48)
    }

    // MARK: - Branch validation

    func testBranchValidationAcceptsCommonShapes() {
        XCTAssertTrue(KanbanCard.isValidBranchName("feature/kanban"))
        XCTAssertTrue(KanbanCard.isValidBranchName("fix-123"))
        XCTAssertTrue(KanbanCard.isValidBranchName("release/v1.2.3"))
    }

    func testBranchValidationRejectsGitAndShellHostileNames() {
        XCTAssertFalse(KanbanCard.isValidBranchName(""))
        XCTAssertFalse(KanbanCard.isValidBranchName("has space"))
        XCTAssertFalse(KanbanCard.isValidBranchName("a..b"))
        XCTAssertFalse(KanbanCard.isValidBranchName("/leading"))
        XCTAssertFalse(KanbanCard.isValidBranchName("trailing/"))
        XCTAssertFalse(KanbanCard.isValidBranchName("x.lock"))
        XCTAssertFalse(KanbanCard.isValidBranchName("rm -rf; $(x)"))
        XCTAssertFalse(KanbanCard.isValidBranchName("a~b"))
    }

    // MARK: - Readiness

    func testReadinessListsEveryMissingField() {
        let card = KanbanCard(projectRoot: root, agentId: "")
        let issues = card.readinessIssues
        XCTAssertTrue(issues.contains("title is empty"))
        XCTAssertTrue(issues.contains("requirement is empty"))
        XCTAssertTrue(issues.contains("no acceptance criteria"))
        XCTAssertTrue(issues.contains("no agent selected"))
        XCTAssertTrue(issues.contains("branch name is invalid"))
        XCTAssertFalse(card.isReady)
    }

    func testReadinessIgnoresBlankCriteriaLines() {
        var card = KanbanCard(
            title: "Feature",
            requirement: "Do the thing",
            acceptanceCriteria: ["   ", ""],
            projectRoot: root,
            agentId: "claude-code"
        )
        XCTAssertTrue(card.readinessIssues.contains("no acceptance criteria"))
        card.acceptanceCriteria = ["works", " "]
        XCTAssertTrue(card.isReady, "\(card.readinessIssues)")
        XCTAssertEqual(card.effectiveCriteria, ["works"])
    }

    // MARK: - Prompt

    func testPromptTextCarriesEveryCardFieldAndTheDoneCommand() {
        let card = KanbanCard(
            title: "Kanban board",
            requirement: "Cards move between columns.",
            acceptanceCriteria: ["Drag works", "State persists"],
            projectRoot: root,
            agentId: "claude-code",
            skill: "develop"
        )
        let prompt = card.promptText(workingDirectory: URL(fileURLWithPath: "/tmp/kanban-project-feature"), branch: "feature/kanban-board", isWorktree: true)
        let lines = prompt.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "/develop", "skill goes first so the CLI treats it as a slash command")
        XCTAssertTrue(prompt.contains("# Feature: Kanban board"))
        XCTAssertTrue(prompt.contains("Cards move between columns."))
        XCTAssertTrue(prompt.contains("- [ ] Drag works"))
        XCTAssertTrue(prompt.contains("- [ ] State persists"))
        XCTAssertTrue(prompt.contains("`/tmp/kanban-project-feature`"))
        XCTAssertTrue(prompt.contains("`feature/kanban-board`"))
        XCTAssertTrue(prompt.contains("kooky-cli card --done --id \(card.id.uuidString)"))
    }

    func testPromptTextWordsInPlaceLaunchDifferently() {
        let card = KanbanCard(title: "T", requirement: "R", acceptanceCriteria: ["A"], projectRoot: root, agentId: "claude-code")
        let inPlace = card.promptText(workingDirectory: root, branch: "main", isWorktree: false)
        XCTAssertTrue(inPlace.contains("working in the repository `/tmp/kanban-project` on branch `main`"), inPlace)
        XCTAssertFalse(inPlace.contains("worktree"), inPlace)
        let worktree = card.promptText(workingDirectory: root, branch: "feature/x", isWorktree: true)
        XCTAssertTrue(worktree.contains("git worktree"), worktree)
    }

    func testPromptTextNormalizesSkillSlash() {
        var card = KanbanCard(title: "T", requirement: "R", acceptanceCriteria: ["A"], projectRoot: root, agentId: "claude-code")
        card.skill = "/plan"
        XCTAssertTrue(card.promptText(workingDirectory: root, branch: "b", isWorktree: true).hasPrefix("/plan\n"))
        card.skill = nil
        XCTAssertTrue(card.promptText(workingDirectory: root, branch: "b", isWorktree: true).hasPrefix("# Feature: T"))
    }

    // MARK: - Events

    func testRecordCapsEventLog() {
        var card = KanbanCard(projectRoot: root, agentId: "x")
        for i in 0..<(KanbanCard.eventCap + 10) {
            card.record("event \(i)")
        }
        XCTAssertEqual(card.events.count, KanbanCard.eventCap)
        XCTAssertEqual(card.events.last?.message, "event \(KanbanCard.eventCap + 9)")
        XCTAssertEqual(card.events.first?.message, "event 10")
    }

    func testClearLaunchLinksKeepsWorktreePin() {
        var card = KanbanCard(projectRoot: root, agentId: "x")
        card.worktreePath = URL(fileURLWithPath: "/tmp/wt")
        card.launchedSessionId = UUID()
        card.launchedWorkspaceId = UUID()
        card.clearLaunchLinks()
        XCTAssertNil(card.launchedSessionId)
        XCTAssertNil(card.launchedWorkspaceId)
        XCTAssertEqual(card.worktreePath, URL(fileURLWithPath: "/tmp/wt"))
    }

    func testProjectRootIsStandardized() {
        let card = KanbanCard(projectRoot: URL(fileURLWithPath: "/tmp/../tmp/x/./y"), agentId: "x")
        XCTAssertEqual(card.projectRoot.path, "/tmp/x/y")
    }
}
