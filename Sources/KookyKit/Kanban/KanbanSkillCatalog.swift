import Foundation

/// One slash-command the card editor can offer. `name` is what gets
/// prefixed to the prompt (`/develop`, `/profile-al-development:plan`).
struct KanbanSkill: Hashable, Identifiable, Sendable {
    enum Scope: String, Sendable, CaseIterable {
        case project
        case user
        case plugin
    }

    var id: String { name }
    let name: String
    let description: String
    let scope: Scope
}

/// Discovers Claude Code skills and slash commands on disk — the same
/// places the CLI loads them from — so the card editor can offer a list
/// instead of asking the user to remember names. Pure filesystem work;
/// callers run it off the main actor.
///
/// Sources, in the order they're listed:
/// - `<repo>/.claude/skills/<name>/SKILL.md` and `<repo>/.claude/commands/*.md`
/// - `~/.claude/skills/<name>/SKILL.md` and `~/.claude/commands/*.md`
/// - installed plugins from `~/.claude/plugins/installed_plugins.json`:
///   `<installPath>/skills/<name>/SKILL.md` → `/<plugin>:<name>`
///
/// Only Claude Code speaks this dialect; the editor shows the picker for
/// Claude-based agents and leaves the field free text for everyone else.
enum KanbanSkillCatalog {
    static func scan(
        projectRoot: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [KanbanSkill] {
        var skills: [KanbanSkill] = []
        var seen: Set<String> = []
        func add(_ skill: KanbanSkill) {
            if seen.insert(skill.name).inserted { skills.append(skill) }
        }
        if let projectRoot {
            let claudeDir = projectRoot.appending(path: ".claude", directoryHint: .isDirectory)
            for skill in skillDirectories(in: claudeDir.appending(path: "skills"), scope: .project, fileManager: fileManager) { add(skill) }
            for skill in commandFiles(in: claudeDir.appending(path: "commands"), scope: .project, fileManager: fileManager) { add(skill) }
        }
        let userClaude = home.appending(path: ".claude", directoryHint: .isDirectory)
        for skill in skillDirectories(in: userClaude.appending(path: "skills"), scope: .user, fileManager: fileManager) { add(skill) }
        for skill in commandFiles(in: userClaude.appending(path: "commands"), scope: .user, fileManager: fileManager) { add(skill) }
        for skill in pluginSkills(claudeDir: userClaude, fileManager: fileManager) { add(skill) }
        return skills
    }

    // MARK: Sources

    private static func skillDirectories(in dir: URL, scope: KanbanSkill.Scope, namespace: String? = nil, fileManager: FileManager) -> [KanbanSkill] {
        guard let entries = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { folder in
                let manifest = folder.appending(path: "SKILL.md")
                guard fileManager.fileExists(atPath: manifest.path) else { return nil }
                let front = frontmatter(of: manifest)
                let base = front["name"] ?? folder.lastPathComponent
                let name = namespace.map { "\($0):\(base)" } ?? base
                return KanbanSkill(name: name, description: front["description"] ?? "", scope: scope)
            }
            .sorted { $0.name < $1.name }
    }

    /// `commands/foo.md` → `foo`; one level of nesting → `dir:foo`, the
    /// way Claude Code namespaces them.
    private static func commandFiles(in dir: URL, scope: KanbanSkill.Scope, fileManager: FileManager) -> [KanbanSkill] {
        guard let entries = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [KanbanSkill] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                guard let nested = try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for file in nested where file.pathExtension == "md" {
                    let front = frontmatter(of: file)
                    result.append(KanbanSkill(
                        name: "\(entry.lastPathComponent):\(file.deletingPathExtension().lastPathComponent)",
                        description: front["description"] ?? "",
                        scope: scope
                    ))
                }
            } else if entry.pathExtension == "md" {
                let front = frontmatter(of: entry)
                result.append(KanbanSkill(
                    name: entry.deletingPathExtension().lastPathComponent,
                    description: front["description"] ?? "",
                    scope: scope
                ))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    private struct InstalledPlugins: Decodable {
        struct Entry: Decodable { let installPath: String }
        let plugins: [String: [Entry]]
    }

    private static func pluginSkills(claudeDir: URL, fileManager: FileManager) -> [KanbanSkill] {
        let manifest = claudeDir.appending(path: "plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: manifest),
              let installed = try? JSONDecoder().decode(InstalledPlugins.self, from: data) else { return [] }
        var result: [KanbanSkill] = []
        for (key, entries) in installed.plugins.sorted(by: { $0.key < $1.key }) {
            // Key shape: `<plugin>@<marketplace>`; the slash-command
            // namespace is the plugin name alone.
            let plugin = key.split(separator: "@", maxSplits: 1).first.map(String.init) ?? key
            for entry in entries {
                let skillsDir = URL(fileURLWithPath: entry.installPath).appending(path: "skills")
                result += skillDirectories(in: skillsDir, scope: .plugin, namespace: plugin, fileManager: fileManager)
            }
        }
        return result
    }

    // MARK: Frontmatter

    /// `key: value` pairs between the leading `---` fences. Good enough for
    /// `name` / `description`; anything multi-line is truncated to its
    /// first line, which is all the picker shows anyway.
    static func frontmatter(of file: URL) -> [String: String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        guard lines.next()?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        while let line = lines.next() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

/// Model names the editor offers as a starting point, plus the model the
/// agent would use when the card leaves the field blank. Free text always
/// wins — vendors rename models faster than any list keeps up, so this is
/// convenience, not validation.
enum KanbanModelSuggestions {
    struct Info: Equatable, Sendable {
        /// Aliases / ids worth offering, the configured default first when
        /// it isn't already an alias.
        var suggestions: [String]
        /// What "default" resolves to according to the agent's own config
        /// files; nil when nothing is configured (the CLI's built-in default
        /// applies, which kooky can't know).
        var defaultModel: String?
    }

    static func suggestions(for template: AgentTemplate?) -> [String] {
        switch template?.rosterId {
        case AgentTemplate.claudeCodeID: return ["fable", "opus", "sonnet", "haiku"]
        case "codex": return ["gpt-5-codex", "gpt-5"]
        case "gemini", "antigravity": return ["gemini-2.5-pro", "gemini-2.5-flash"]
        case "copilot": return ["claude-sonnet-4.5", "gpt-5"]
        default: return []
        }
    }

    /// Filesystem read — call off the main actor. Reads the same files the
    /// CLIs read, nearest scope first:
    /// - Claude Code: `<repo>/.claude/settings.local.json`,
    ///   `<repo>/.claude/settings.json`, `~/.claude/settings.json` — key `model`.
    /// - Codex: `<repo>/.codex/config.toml`, `~/.codex/config.toml` — `model = "…"`.
    /// - Gemini CLI: `<repo>/.gemini/settings.json`, `~/.gemini/settings.json`
    ///   — `model` or `model.name`.
    static func resolve(
        for template: AgentTemplate?,
        projectRoot: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Info {
        var info = Info(suggestions: suggestions(for: template), defaultModel: nil)
        switch template?.rosterId {
        case AgentTemplate.claudeCodeID:
            let candidates = [
                projectRoot?.appending(path: ".claude/settings.local.json"),
                projectRoot?.appending(path: ".claude/settings.json"),
                home.appending(path: ".claude/settings.json"),
            ].compactMap { $0 }
            info.defaultModel = candidates.lazy.compactMap { jsonString(at: $0, keyPath: ["model"]) }.first
        case "codex":
            let candidates = [
                projectRoot?.appending(path: ".codex/config.toml"),
                home.appending(path: ".codex/config.toml"),
            ].compactMap { $0 }
            info.defaultModel = candidates.lazy.compactMap { tomlTopLevelString(at: $0, key: "model") }.first
        case "gemini", "antigravity":
            let candidates = [
                projectRoot?.appending(path: ".gemini/settings.json"),
                home.appending(path: ".gemini/settings.json"),
            ].compactMap { $0 }
            info.defaultModel = candidates.lazy.compactMap {
                jsonString(at: $0, keyPath: ["model"]) ?? jsonString(at: $0, keyPath: ["model", "name"])
            }.first
        default:
            break
        }
        if let configured = info.defaultModel, !info.suggestions.contains(configured) {
            info.suggestions.insert(configured, at: 0)
        }
        return info
    }

    private static func jsonString(at url: URL, keyPath: [String]) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var node: Any = root
        for key in keyPath {
            guard let dict = node as? [String: Any], let next = dict[key] else { return nil }
            node = next
        }
        guard let value = node as? String, !value.isEmpty else { return nil }
        return value
    }

    /// `key = "value"` at the top of a TOML file (before the first `[table]`
    /// header). Enough for Codex's `model`; no general TOML parser needed.
    private static func tomlTopLevelString(at url: URL, key: String) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard line.hasPrefix(key) else { continue }
            let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            var value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") { value = value[..<hash].trimmingCharacters(in: .whitespaces) }
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
