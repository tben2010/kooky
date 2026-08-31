import XCTest
@testable import KookyKit

final class OpenInAppTests: XCTestCase {
    private func app(_ id: String) -> OpenInApp {
        OpenInApp.catalogById[id] ?? OpenInApp(id: id, title: id, bundleIdentifiers: [])
    }

    func testCatalogIdsAreUnique() {
        let ids = OpenInApp.catalog.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "catalog ids must be unique")
        XCTAssertEqual(OpenInApp.catalogById.count, OpenInApp.catalog.count)
    }

    func testCatalogAlwaysIncludesFinder() {
        // Finder always resolves on macOS, so it guarantees the picker is
        // never empty — pin it in the catalog.
        XCTAssertNotNil(OpenInApp.catalogById["finder"])
    }

    func testEveryCatalogAppHasABundleId() {
        for app in OpenInApp.catalog {
            XCTAssertFalse(app.title.isEmpty, "\(app.id) missing title")
            XCTAssertFalse(app.bundleIdentifiers.isEmpty, "\(app.id) missing bundle ids")
        }
    }

    func testFileLinkCatalogContainsEditorsButNotFolderOnlyApps() {
        let ids = Set(OpenInApp.fileLinkCatalog.map(\.id))
        XCTAssertTrue(ids.contains("vscode"))
        XCTAssertTrue(ids.contains("cursor"))
        XCTAssertTrue(ids.contains("xcode"))
        XCTAssertFalse(ids.contains("terminal"))
        XCTAssertFalse(ids.contains("finder"))
    }

    func testBrowserLinkCatalogIsValidAndUnique() {
        let ids = OpenInApp.browserLinkCatalog.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertTrue(ids.contains("safari"))
        XCTAssertTrue(ids.contains("chrome"))
        for browser in OpenInApp.browserLinkCatalog {
            XCTAssertFalse(browser.title.isEmpty, "\(browser.id) missing title")
            XCTAssertFalse(browser.bundleIdentifiers.isEmpty, "\(browser.id) missing bundle ids")
        }
    }

    func testPreferredLinkAppUsesOnlyAvailableChoice() {
        let available = [app("vscode"), app("cursor")]
        XCTAssertEqual(OpenInApp.preferred(id: "cursor", available: available)?.id, "cursor")
        XCTAssertNil(OpenInApp.preferred(id: nil, available: available))
        XCTAssertNil(OpenInApp.preferred(id: "xcode", available: available))
        XCTAssertNil(OpenInApp.preferred(id: "future-editor", available: available))
    }

    func testOrderedRespectsUserOrderThenCatalog() {
        let apps = [app("vscode"), app("cursor"), app("finder")]
        let ordered = OpenInApp.ordered(apps, order: ["finder", "vscode"])
        XCTAssertEqual(ordered.map(\.id), ["finder", "vscode", "cursor"])
    }

    func testOrderedIgnoresUnknownAndUninstalledIds() {
        let apps = [app("vscode"), app("finder")]
        // "zed" isn't in `apps` (not installed), "bogus" isn't a real id —
        // both are dropped; the present apps keep catalog order.
        let ordered = OpenInApp.ordered(apps, order: ["bogus", "zed", "finder"])
        XCTAssertEqual(ordered.map(\.id), ["finder", "vscode"])
    }

    func testOrderedEmptyOrderIsCatalogOrder() {
        let apps = [app("cursor"), app("vscode"), app("finder")]
        XCTAssertEqual(OpenInApp.ordered(apps, order: []).map(\.id), apps.map(\.id))
    }

    func testEffectiveDefaultPrefersVisibleLastUsed() {
        let visible = [app("vscode"), app("cursor"), app("finder")]
        XCTAssertEqual(OpenInApp.effectiveDefault(lastUsedId: "cursor", visible: visible)?.id, "cursor")
    }

    func testEffectiveDefaultFallsBackToFirstWhenLastUsedHidden() {
        let visible = [app("vscode"), app("finder")]
        // last-used "cursor" isn't visible (hidden / uninstalled) → first visible.
        XCTAssertEqual(OpenInApp.effectiveDefault(lastUsedId: "cursor", visible: visible)?.id, "vscode")
    }

    func testEffectiveDefaultFirstWhenNoLastUsed() {
        let visible = [app("finder"), app("vscode")]
        XCTAssertEqual(OpenInApp.effectiveDefault(lastUsedId: nil, visible: visible)?.id, "finder")
    }

    func testEffectiveDefaultNilWhenNothingVisible() {
        XCTAssertNil(OpenInApp.effectiveDefault(lastUsedId: "vscode", visible: []))
    }

    // MARK: - projectTarget (workspace file beats folder)

    private func makeProjectDir(_ entries: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openin-\(UUID().uuidString)/MyApp", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for entry in entries {
            let url = dir.appendingPathComponent(entry)
            if entry.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data().write(to: url)
            }
        }
        return dir
    }

    func testVSCodeOpensTheCodeWorkspaceFileWhenPresent() throws {
        let dir = try makeProjectDir(["MyApp.code-workspace", "README.md", "src/"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        for id in ["vscode", "cursor", "windsurf", "kiro"] {
            XCTAssertEqual(OpenInResolver.projectTarget(for: dir, app: app(id)).lastPathComponent, "MyApp.code-workspace", id)
        }
    }

    func testFolderWithoutWorkspaceFileOpensAsFolder() throws {
        let dir = try makeProjectDir(["README.md", "src/"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        XCTAssertEqual(OpenInResolver.projectTarget(for: dir, app: app("vscode")), dir)
        XCTAssertEqual(OpenInResolver.projectTarget(for: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), app: app("vscode")).lastPathComponent.hasPrefix("nonexistent"), true)
    }

    func testWorkspaceNamedAfterFolderWinsElseAlphabetical() throws {
        let dir = try makeProjectDir(["zeta.code-workspace", "MyApp.code-workspace", "alpha.code-workspace"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        XCTAssertEqual(OpenInResolver.projectTarget(for: dir, app: app("vscode")).lastPathComponent, "MyApp.code-workspace")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("MyApp.code-workspace"))
        XCTAssertEqual(OpenInResolver.projectTarget(for: dir, app: app("vscode")).lastPathComponent, "alpha.code-workspace")
    }

    func testXcodePrefersWorkspaceOverProjectAndOthersIgnoreWorkspaceFiles() throws {
        let dir = try makeProjectDir(["MyApp.xcodeproj/", "MyApp.xcworkspace/", "MyApp.code-workspace"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        XCTAssertEqual(OpenInResolver.projectTarget(for: dir, app: app("xcode")).lastPathComponent, "MyApp.xcworkspace")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("MyApp.xcworkspace"))
        XCTAssertEqual(OpenInResolver.projectTarget(for: dir, app: app("xcode")).lastPathComponent, "MyApp.xcodeproj")
        // Terminals, Finder, Zed: the folder, always.
        for id in ["terminal", "finder", "zed", "sublime"] {
            XCTAssertEqual(OpenInResolver.projectTarget(for: dir, app: app(id)), dir, id)
        }
    }

    func testHiddenWorkspaceFilesAreIgnored() throws {
        let dir = try makeProjectDir([".hidden.code-workspace"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        XCTAssertEqual(OpenInResolver.projectTarget(for: dir, app: app("vscode")), dir)
    }
}
