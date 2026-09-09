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
    static var runner: @Sendable (_ shellCommand: String, _ cwd: URL) async -> Result<String, DraftError> = { command, cwd in
        await runInLoginShell(command, cwd: cwd, timeout: timeout)
    }

    /// How long a headless run may take before it is killed — generous,
    /// the agent may actually read code, but a hung run must not strand
    /// the editor.
    nonisolated static let timeout: Duration = .seconds(180)

    /// True when "draft with agent" can work for this template.
    static func supports(_ template: AgentTemplate?) -> Bool {
        template?.rosterId == AgentTemplate.claudeCodeID
    }

    /// The full shell command line for one draft run, or nil for agents
    /// without a known headless mode. `extraDirectories` become `--add-dir`
    /// options: a headless run has nobody to approve reading a file outside
    /// the project root, so attachment folders must be granted up front.
    static func command(template: AgentTemplate?, model: String?, prompt: String, extraDirectories: [String] = []) -> String? {
        guard supports(template) else { return nil }
        var parts = ["claude", "-p", KookyShellIntegration.quote(prompt), "--permission-mode", "plan"]
        for directory in extraDirectories {
            parts.append("--add-dir")
            parts.append(KookyShellIntegration.quote(directory))
        }
        if let modelOptions = KanbanLaunchCoordinator.modelOptions(template: template, model: model) {
            parts.append(modelOptions)
        }
        return parts.joined(separator: " ")
    }

    /// Parent folders of the attachments that still exist, deduplicated in
    /// first-seen order — what `command` grants via `--add-dir`. Missing
    /// files grant nothing (their folder may be gone too).
    static func attachmentDirectories(_ attachments: [String]) -> [String] {
        var seen = Set<String>()
        var directories: [String] = []
        for path in attachments where KanbanCard.attachmentExists(path) {
            let directory = (path as NSString).deletingLastPathComponent
            guard !directory.isEmpty, seen.insert(directory).inserted else { continue }
            directories.append(directory)
        }
        return directories
    }

    /// The instruction the agent gets. Language follows the card (the model
    /// mirrors the title's language); the JSON contract is spelled out hard
    /// because the whole answer must parse.
    static func prompt(title: String, requirement: String, criteria: [String], attachments: [String] = []) -> String {
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
        if !attachments.isEmpty {
            lines.append("")
            lines.append("Attached files (absolute paths). Read every one of them and take their content into account when writing the requirement and the acceptance criteria — concrete demands stated in an attachment must show up there:")
            lines.append(contentsOf: KanbanCard.attachmentLines(attachments))
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
        attachments: [String] = [],
        projectRoot: URL,
        template: AgentTemplate?,
        model: String?
    ) async -> Result<KanbanCardDraft, DraftError> {
        let prompt = prompt(title: title, requirement: requirement, criteria: criteria, attachments: attachments)
        guard let command = command(template: template, model: model, prompt: prompt, extraDirectories: attachmentDirectories(attachments)) else {
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

    /// What one headless run ended as, before it is turned into a message.
    private enum RunEvent: Sendable {
        case exited(Int32)
        case stdout(Data)
        case stderr(Data)
        case timedOut
    }

    /// Message for a run the calling task cancelled (the editor closed).
    nonisolated static let cancelledMessage = "draft cancelled"

    /// Runs `command` through `zsh -lc` in `cwd` so the user's PATH applies;
    /// KOOKY_* session vars are stripped so the headless run can't ping
    /// this window's hooks or trip the agent-launch guard.
    ///
    /// Nothing here blocks a thread: the exit arrives through
    /// `terminationHandler`, both pipes are drained with `FileHandle.bytes`
    /// (so a chatty agent can't deadlock on a full pipe), and the timeout is
    /// a sleeping child task racing the exit. Cancelling the calling task
    /// terminates the process — closing the editor kills the agent.
    nonisolated static func runInLoginShell(_ command: String, cwd: URL, timeout: Duration) async -> Result<String, DraftError> {
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
        // Installed BEFORE `run()`: a process that exits at once would
        // otherwise fire into nothing, and the exit wait below would hang.
        let (exits, exitSink) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { finished in
            exitSink.yield(finished.terminationStatus)
            exitSink.finish()
        }
        do {
            try process.run()
        } catch {
            return .failure(DraftError(message: "couldn't start the agent: \(error.localizedDescription)"))
        }

        var status: Int32?
        var output = Data()
        var errors = Data()
        var timedOut = false
        await withTaskCancellationHandler {
            await withTaskGroup(of: RunEvent.self) { group in
                group.addTask {
                    var iterator = exits.makeAsyncIterator()
                    return .exited(await iterator.next() ?? -1)
                }
                group.addTask { .stdout(await drain(stdout.fileHandleForReading)) }
                group.addTask { .stderr(await drain(stderr.fileHandleForReading)) }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return .timedOut
                }
                // Exit + both pipes; once all three are in, the sleeper is
                // cancelled instead of waiting out the full timeout.
                var outstanding = 3
                for await event in group {
                    switch event {
                    case .exited(let code):
                        status = code
                        outstanding -= 1
                    case .stdout(let data):
                        output = data
                        outstanding -= 1
                    case .stderr(let data):
                        errors = data
                        outstanding -= 1
                    case .timedOut:
                        // The sleeper also reports in when it is cancelled
                        // below — only a timeout that beats the exit counts.
                        guard status == nil, !Task.isCancelled else { continue }
                        timedOut = true
                        if process.isRunning { process.terminate() }
                        group.cancelAll()
                        continue
                    }
                    if outstanding == 0 { group.cancelAll() }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        if Task.isCancelled {
            return .failure(DraftError(message: cancelledMessage))
        }
        if timedOut {
            return .failure(DraftError(message: "the agent didn't answer within \(timeout.components.seconds)s"))
        }
        guard let status, status == 0 else {
            let error = singleLine(String((String(data: errors, encoding: .utf8) ?? "").prefix(160)))
            return .failure(DraftError(message: "agent exited with status \(status ?? -1)\(error.isEmpty ? "" : ": \(error)")"))
        }
        return .success(String(data: output, encoding: .utf8) ?? "")
    }

    /// Everything the handle delivers until EOF; whatever arrived so far
    /// when the read is cancelled.
    ///
    /// `readabilityHandler` (a per-handle dispatch source), not
    /// `FileHandle.bytes`: two concurrent `bytes` iterations share one
    /// reader, and the idle stderr read starves the stdout one — stdout
    /// stalled after ~36 KB while the agent blocked on a full pipe.
    nonisolated private static func drain(_ handle: FileHandle) async -> Data {
        let (chunks, sink) = AsyncStream.makeStream(of: Data.self)
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF — the writer closed its end.
                handle.readabilityHandler = nil
                sink.finish()
            } else {
                sink.yield(chunk)
            }
        }
        var data = Data()
        // Ends at EOF, or early when the task is cancelled.
        for await chunk in chunks { data.append(chunk) }
        handle.readabilityHandler = nil
        return data
    }
}
