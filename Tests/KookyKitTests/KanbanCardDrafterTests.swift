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

    func testPromptListsAttachmentsWithReadInstructionAndMissingFlag() {
        let previous = KanbanCard.attachmentExists
        defer { KanbanCard.attachmentExists = previous }
        KanbanCard.attachmentExists = { $0.hasSuffix("spec.md") }

        let prompt = KanbanCardDrafter.prompt(
            title: "Ticker", requirement: "", criteria: [],
            attachments: ["/docs/spec.md", "/docs/mockup.png"]
        )
        XCTAssertTrue(prompt.contains("Attached files"), prompt)
        XCTAssertTrue(prompt.contains("Read every one of them"), prompt)
        XCTAssertTrue(prompt.contains("- `/docs/spec.md`\n"), prompt)
        XCTAssertTrue(prompt.contains("- `/docs/mockup.png` (\(KanbanCard.missingAttachmentNote))"), prompt)
        let sectionIndex = prompt.range(of: "Attached files")!.lowerBound
        let writeIndex = prompt.range(of: "Write, in the same language")!.lowerBound
        XCTAssertLessThan(sectionIndex, writeIndex, "attachments precede the output instructions")

        XCTAssertFalse(KanbanCardDrafter.prompt(title: "X", requirement: "", criteria: []).contains("Attached files"))
    }

    func testCommandGrantsAttachmentDirectories() throws {
        let command = try XCTUnwrap(KanbanCardDrafter.command(
            template: .claudeCode, model: nil, prompt: "p",
            extraDirectories: ["/docs/a b", "/spec"]
        ))
        XCTAssertTrue(command.contains("--add-dir '/docs/a b' --add-dir '/spec'"), command)
        XCTAssertTrue(command.hasPrefix("claude -p 'p' --permission-mode plan"), command)
    }

    func testAttachmentDirectoriesDedupeAndSkipMissing() {
        let previous = KanbanCard.attachmentExists
        defer { KanbanCard.attachmentExists = previous }
        KanbanCard.attachmentExists = { !$0.contains("gone") }
        let dirs = KanbanCardDrafter.attachmentDirectories([
            "/docs/spec.md", "/docs/mockup.png", "/other/gone.txt", "/spec/x.md",
        ])
        XCTAssertEqual(dirs, ["/docs", "/spec"])
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

    func testDraftPassesAttachmentsIntoPromptAndAddDir() async throws {
        let previousRunner = KanbanCardDrafter.runner
        let previousExists = KanbanCard.attachmentExists
        defer {
            KanbanCardDrafter.runner = previousRunner
            KanbanCard.attachmentExists = previousExists
        }
        KanbanCard.attachmentExists = { $0.hasSuffix("spec.md") }
        nonisolated(unsafe) var seen: String?
        KanbanCardDrafter.runner = { command, _ in
            seen = command
            return .success(#"{"requirement": "R", "acceptanceCriteria": ["a"]}"#)
        }
        _ = await KanbanCardDrafter.draft(
            title: "Ticker", requirement: "", criteria: [],
            attachments: ["/docs/spec.md", "/docs/gone.png"],
            projectRoot: root, template: .claudeCode, model: nil
        )
        let command = try XCTUnwrap(seen)
        XCTAssertTrue(command.contains("--add-dir '/docs'"), command)
        XCTAssertEqual(command.components(separatedBy: "--add-dir").count, 2, "one grant per folder: \(command)")
        XCTAssertTrue(command.contains("/docs/spec.md"), command)
        XCTAssertTrue(command.contains("/docs/gone.png"), "missing files are still named, just flagged: \(command)")
        XCTAssertTrue(command.contains("MISSING"), command)
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

    // MARK: - Process runner (real zsh)

    private let shellCwd = FileManager.default.temporaryDirectory

    func testRunnerReturnsStdoutOfASuccessfulCommand() async throws {
        let result = await KanbanCardDrafter.runInLoginShell(#"printf '{"requirement":"r"}'"#, cwd: shellCwd, timeout: .seconds(30))
        XCTAssertEqual(try result.get(), #"{"requirement":"r"}"#)
    }

    /// More than the 64 KB pipe buffer: the drains must run while the
    /// process is still writing, or it would block on a full pipe and the
    /// exit would never come.
    func testRunnerDrainsOutputLargerThanThePipeBuffer() async throws {
        let result = await KanbanCardDrafter.runInLoginShell("head -c 300000 /dev/zero | tr '\\0' x", cwd: shellCwd, timeout: .seconds(30))
        XCTAssertEqual(try result.get().count, 300_000)
    }

    func testRunnerReportsExitStatusWithStderrHead() async {
        let result = await KanbanCardDrafter.runInLoginShell("echo boom >&2; exit 3", cwd: shellCwd, timeout: .seconds(30))
        XCTAssertEqual(result, .failure(.init(message: "agent exited with status 3: boom")))
    }

    func testRunnerTimesOutAndTerminatesTheProcess() async {
        let clock = ContinuousClock()
        let start = clock.now
        let result = await KanbanCardDrafter.runInLoginShell("sleep 30", cwd: shellCwd, timeout: .milliseconds(500))
        XCTAssertEqual(result, .failure(.init(message: "the agent didn't answer within 0s")))
        XCTAssertLessThan(clock.now - start, .seconds(10), "returns right after the timeout, not after the 30s sleep")
    }

    func testCancellingTheCallerTerminatesTheProcess() async {
        let clock = ContinuousClock()
        let start = clock.now
        let run = Task {
            await KanbanCardDrafter.runInLoginShell("sleep 30", cwd: shellCwd, timeout: .seconds(60))
        }
        try? await Task.sleep(for: .milliseconds(300))
        run.cancel()
        let result = await run.value
        XCTAssertEqual(result, .failure(.init(message: KanbanCardDrafter.cancelledMessage)))
        XCTAssertLessThan(clock.now - start, .seconds(10), "cancel kills the agent instead of waiting it out")
    }
}
