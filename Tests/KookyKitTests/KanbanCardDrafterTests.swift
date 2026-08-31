import XCTest
@testable import KookyKit

@MainActor
final class KanbanCardDrafterTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/kanban-project")

    // MARK: - Command / support

    func testOnlyClaudeBasedAgentsAreSupported() {
        XCTAssertTrue(KanbanCardDrafter.supports(.claudeCode))
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "claude-opus", title: "Opus", command: "", baseAgentId: AgentTemplate.claudeCodeID))
        XCTAssertTrue(KanbanCardDrafter.supports(custom), "customs based on Claude inherit headless drafting")
        XCTAssertFalse(KanbanCardDrafter.supports(.codex))
        XCTAssertFalse(KanbanCardDrafter.supports(.terminal))
        XCTAssertFalse(KanbanCardDrafter.supports(nil))
    }

    func testCommandShape() throws {
        let command = try XCTUnwrap(KanbanCardDrafter.command(template: .claudeCode, model: "opus", prompt: "do it"))
        XCTAssertTrue(command.hasPrefix("claude -p 'do it' --permission-mode plan"), command)
        XCTAssertTrue(command.hasSuffix("--model opus"), command)
        let plain = try XCTUnwrap(KanbanCardDrafter.command(template: .claudeCode, model: nil, prompt: "x"))
        XCTAssertFalse(plain.contains("--model"), plain)
        XCTAssertNil(KanbanCardDrafter.command(template: .codex, model: nil, prompt: "x"))
    }

    func testPromptCarriesCardStateAndJSONContract() {
        let prompt = KanbanCardDrafter.prompt(
            title: "Ticker App",
            requirement: "Ein Laufband\nim RoleCenter",
            criteria: ["läuft", "  ", "konfigurierbar"]
        )
        XCTAssertTrue(prompt.contains("Card title: Ticker App"))
        XCTAssertTrue(prompt.contains("Ein Laufband"))
        XCTAssertTrue(prompt.contains("- läuft"))
        XCTAssertTrue(prompt.contains("- konfigurierbar"))
        XCTAssertFalse(prompt.contains("-  \n"), "blank criteria are dropped")
        XCTAssertTrue(prompt.contains(#"{"requirement""#))
        XCTAssertTrue(prompt.contains("Do not modify anything."))

        let bare = KanbanCardDrafter.prompt(title: "X", requirement: "  ", criteria: [])
        XCTAssertFalse(bare.contains("Notes so far"))
        XCTAssertFalse(bare.contains("Existing acceptance criteria"))
    }

    // MARK: - Parsing

    func testParseAcceptsPlainFencedAndPrefacedJSON() throws {
        let object = #"{"requirement": "Req", "acceptanceCriteria": ["a", "b"]}"#
        let expected = KanbanCardDraft(requirement: "Req", acceptanceCriteria: ["a", "b"])
        XCTAssertEqual(try KanbanCardDrafter.parseDraft(from: object).get(), expected)
        XCTAssertEqual(try KanbanCardDrafter.parseDraft(from: "```json\n\(object)\n```").get(), expected)
        XCTAssertEqual(try KanbanCardDrafter.parseDraft(from: "Here you go:\n\(object)\nHope that helps!").get(), expected)
    }

    func testParseFailuresAreReadable() {
        if case .success = KanbanCardDrafter.parseDraft(from: "no json here") {
            XCTFail("garbage must not parse")
        }
        if case .failure(let error) = KanbanCardDrafter.parseDraft(from: "") {
            XCTAssertEqual(error.message, "the agent returned nothing")
        }
        if case .failure(let error) = KanbanCardDrafter.parseDraft(from: "I refuse because reasons") {
            XCTAssertTrue(error.message.contains("I refuse"), error.message)
        }
    }

    // MARK: - Orchestration (injected runner)

    func testDraftRunsCommandInProjectRootAndCleansResult() async throws {
        let previous = KanbanCardDrafter.runner
        defer { KanbanCardDrafter.runner = previous }
        nonisolated(unsafe) var seen: (command: String, cwd: URL)?
        KanbanCardDrafter.runner = { command, cwd in
            seen = (command, cwd)
            return .success(#"{"requirement": "  Req  ", "acceptanceCriteria": [" a ", "", "b"]}"#)
        }
        let result = await KanbanCardDrafter.draft(
            title: "Ticker", requirement: "notes", criteria: ["x"],
            projectRoot: root, template: .claudeCode, model: "opus"
        )
        XCTAssertEqual(try result.get(), KanbanCardDraft(requirement: "Req", acceptanceCriteria: ["a", "b"]))
        let call = try XCTUnwrap(seen)
        XCTAssertEqual(call.cwd, root)
        XCTAssertTrue(call.command.contains("--permission-mode plan"))
        XCTAssertTrue(call.command.contains("Ticker"))
    }

    func testDraftSurfacesRunnerFailureAndUnsupportedAgent() async {
        let previous = KanbanCardDrafter.runner
        defer { KanbanCardDrafter.runner = previous }
        KanbanCardDrafter.runner = { _, _ in .failure(.init(message: "boom")) }
        let failed = await KanbanCardDrafter.draft(title: "T", requirement: "", criteria: [], projectRoot: root, template: .claudeCode, model: nil)
        if case .failure(let error) = failed {
            XCTAssertEqual(error.message, "boom")
        } else {
            XCTFail("runner failure must surface")
        }
        let unsupported = await KanbanCardDrafter.draft(title: "T", requirement: "", criteria: [], projectRoot: root, template: .droid, model: nil)
        if case .success = unsupported { XCTFail("droid has no headless drafting") }
    }
}
