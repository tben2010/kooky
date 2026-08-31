import Foundation

/// What the drafting agent hands back for a card — requirement text plus
/// testable acceptance criteria. Decoded from the JSON object the prompt
/// demands as the entire answer.
struct KanbanCardDraft: Codable, Equatable, Sendable {
    var requirement: String
    var acceptanceCriteria: [String]
}

/// "Draft with agent" for the card editor: runs the card's agent HEADLESS
/// in the project root (so it can read the code and use real names), asks
/// it to write requirement + acceptance criteria, and returns them for the
/// editor to preview — nothing lands in the card without the user's apply.
///
/// Claude Code only for now: `claude -p` prints one response and exits, and
/// `--permission-mode plan` lets it read the repo without a permission
/// prompt stalling a run nobody can see (and without letting it edit).
@MainActor
enum KanbanCardDrafter {
    /// Failure carrier — the message the editor shows inline.
    struct DraftError: Error, Equatable {
        let message: String
    }

    /// Test seam: runs `shellCommand` through the user's login shell in
    /// `cwd` and returns stdout. A login shell because the app's own PATH
    /// (LaunchServices) doesn't know where `claude` lives — the user's
    /// shell does, same as every kooky terminal.
    nonisolated(unsafe) static var runner: @Sendable (_ shellCommand: String, _ cwd: URL) async -> Result<String, DraftError> = { command, cwd in
        await Task.detached(priority: .userInitiated) {
            runInLoginShell(command, cwd: cwd)
        }.value
    }

    /// Seconds before a headless run is killed — generous, the agent may
    /// actually read code, but a hung run must not strand the editor.
    nonisolated static let timeout: TimeInterval = 180

    /// True when "draft with agent" can work for this template.
    static func supports(_ template: AgentTemplate?) -> Bool {
        template?.rosterId == AgentTemplate.claudeCodeID
    }

    /// The full shell command line for one draft run, or nil for agents
    /// without a known headless mode.
    static func command(template: AgentTemplate?, model: String?, prompt: String) -> String? {
        guard supports(template) else { return nil }
        var parts = ["claude", "-p", KookyShellIntegration.quote(prompt), "--permission-mode", "plan"]
        if let modelOptions = KanbanLaunchCoordinator.modelOptions(template: template, model: model) {
            parts.append(modelOptions)
        }
        return parts.joined(separator: " ")
    }

    /// The instruction the agent gets. Language follows the card (the model
    /// mirrors the title's language); the JSON contract is spelled out hard
    /// because the whole answer must parse.
    static func prompt(title: String, requirement: String, criteria: [String]) -> String {
        var lines: [String] = []
        lines.append("You are drafting a Kanban card for a feature in the repository at your current working directory.")
        lines.append("Explore the code as needed to use its real names and conventions. Do not modify anything.")
        lines.append("")
        lines.append("Card title: \(singleLine(title))")
        let existing = requirement.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty {
            lines.append("Notes so far (rewrite into a proper requirement):")
            lines.append(existing)
        }
        let kept = criteria.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !kept.isEmpty {
            lines.append("Existing acceptance criteria (keep their intent, refine the wording):")
            for criterion in kept { lines.append("- \(criterion)") }
        }
        lines.append("")
        lines.append("Write, in the same language as the card title:")
        lines.append("1. a concise requirement description (a few sentences, plain text)")
        lines.append("2. 3-7 short, individually testable acceptance criteria")
        lines.append("")
        lines.append("Answer with ONLY one JSON object, no markdown fences, no commentary:")
        lines.append(#"{"requirement": "…", "acceptanceCriteria": ["…", "…"]}"#)
        return lines.joined(separator: "\n")
    }

    /// One draft round-trip. `model` is the card's model override (may be
    /// nil); `title` must be non-empty (the button is disabled otherwise).
    static func draft(
        title: String,
        requirement: String,
        criteria: [String],
        projectRoot: URL,
        template: AgentTemplate?,
        model: String?
    ) async -> Result<KanbanCardDraft, DraftError> {
        guard let command = command(template: template, model: model, prompt: prompt(title: title, requirement: requirement, criteria: criteria)) else {
            return .failure(DraftError(message: "drafting needs a Claude Code based agent"))
        }
        switch await runner(command, projectRoot) {
        case .failure(let error):
            return .failure(error)
        case .success(let output):
            return parseDraft(from: output).map { draft in
                var cleaned = draft
                cleaned.requirement = draft.requirement.trimmingCharacters(in: .whitespacesAndNewlines)
                cleaned.acceptanceCriteria = draft.acceptanceCriteria
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return cleaned
            }
        }
    }

    /// Extracts the draft JSON from the agent's stdout. Models fence or
    /// preface answers despite instructions, so: exact parse first, then
    /// the outermost `{ … }` slice of the text.
    nonisolated static func parseDraft(from output: String) -> Result<KanbanCardDraft, DraftError> {
        let decoder = JSONDecoder()
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let draft = try? decoder.decode(KanbanCardDraft.self, from: Data(trimmed.utf8)) {
            return .success(draft)
        }
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first < last {
            let slice = trimmed[first...last]
            if let draft = try? decoder.decode(KanbanCardDraft.self, from: Data(slice.utf8)) {
                return .success(draft)
            }
        }
        let head = singleLine(String(trimmed.prefix(160)))
        return .failure(DraftError(message: head.isEmpty
            ? "the agent returned nothing"
            : "couldn't read the agent's answer: \(head)"))
    }

    // MARK: - Process

    /// Blocking; callers hop off the main actor. `zsh -lc` so the user's
    /// PATH applies; KOOKY_* session vars are stripped so the headless run
    /// can't ping this window's hooks or trip the agent-launch guard.
    nonisolated private static func runInLoginShell(_ command: String, cwd: URL) -> Result<String, DraftError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("KOOKY_") { env.removeValue(forKey: key) }
        process.environment = env
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .failure(DraftError(message: "couldn't start the agent: \(error.localizedDescription)"))
        }
        // Drain on background threads so a chatty agent can't deadlock on a
        // full pipe while we wait for exit.
        let outData = DrainBox(), errData = DrainBox()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData.data = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData.data = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            return .failure(DraftError(message: "the agent didn't answer within \(Int(timeout))s"))
        }
        group.wait()
        let output = String(data: outData.data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let error = singleLine(String((String(data: errData.data, encoding: .utf8) ?? "").prefix(160)))
            return .failure(DraftError(message: "agent exited with status \(process.terminationStatus)\(error.isEmpty ? "" : ": \(error)")"))
        }
        return .success(output)
    }

    /// Reference box for the pipe drains — written once per thread before
    /// `group.wait()` provides the happens-before edge.
    private final class DrainBox: @unchecked Sendable {
        var data = Data()
    }
}
