import AppKit
import XCTest
@testable import KookyKit

@MainActor
final class KanbanAttachmentStoreTests: XCTestCase {
    private var tempRoot: URL!
    private let cardId = UUID()

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-attachments-\(UUID().uuidString)", isDirectory: true)
        KanbanAttachmentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        KanbanAttachmentStore.rootOverride = nil
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private var png: Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - Store

    func testStoreWritesTimestampedPNGUnderCardFolderAndAvoidsCollisions() throws {
        let now = Date(timeIntervalSince1970: 1_757_300_000)
        let first = try KanbanAttachmentStore.store(pngData: png, cardId: cardId, now: now)
        let second = try KanbanAttachmentStore.store(pngData: png, cardId: cardId, now: now)
        XCTAssertTrue(first.hasPrefix(tempRoot.standardizedFileURL.appendingPathComponent(cardId.uuidString).path), first)
        XCTAssertTrue(first.hasSuffix(".png"), first)
        XCTAssertTrue(KanbanCard.attachmentFileName(first).hasPrefix("screenshot-"), first)
        XCTAssertNotEqual(first, second, "same second → counter suffix, never an overwrite")
        XCTAssertTrue(second.hasSuffix("-2.png"), second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second))
        XCTAssertTrue(KanbanAttachmentStore.isManaged(first))
        XCTAssertFalse(KanbanAttachmentStore.isManaged("/Users/me/Desktop/spec.md"))
        XCTAssertFalse(KanbanAttachmentStore.isManaged(tempRoot.path), "the root itself is not a managed file")
    }

    func testRemoveOrphansKeepsListedFilesAndDropsEmptyFolder() throws {
        let kept = try KanbanAttachmentStore.store(pngData: png, cardId: cardId)
        let dropped = try KanbanAttachmentStore.store(pngData: png, cardId: cardId, now: Date().addingTimeInterval(1))
        KanbanAttachmentStore.removeOrphans(cardId: cardId, keeping: [kept, "/elsewhere/spec.md"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropped))

        KanbanAttachmentStore.removeOrphans(cardId: cardId, keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: KanbanAttachmentStore.directory(for: cardId).path), "empty folder goes too")

        // No folder at all is fine.
        KanbanAttachmentStore.removeOrphans(cardId: UUID(), keeping: [])
    }

    func testRemoveAllDeletesTheCardFolder() throws {
        _ = try KanbanAttachmentStore.store(pngData: png, cardId: cardId)
        KanbanAttachmentStore.removeAll(cardId: cardId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: KanbanAttachmentStore.directory(for: cardId).path))
    }

    // MARK: - Import decision

    func testFilesWinOverImageDataAndNonFileURLsAreIgnored() {
        let file = URL(fileURLWithPath: "/tmp/shot.png")
        let sources = KanbanAttachmentImport.sources(fileURLs: [file, URL(string: "https://example.com/x.png")!], imageData: png)
        XCTAssertEqual(sources, [.file(file)])
        XCTAssertEqual(KanbanAttachmentImport.sources(fileURLs: [], imageData: png), [.image(pngData: png)])
        XCTAssertEqual(KanbanAttachmentImport.sources(fileURLs: [], imageData: nil), [])
        XCTAssertEqual(KanbanAttachmentImport.sources(fileURLs: [], imageData: Data("not an image".utf8)), [])
    }

    func testPNGPassesThroughAndTIFFIsConverted() throws {
        XCTAssertEqual(KanbanAttachmentImport.pngData(from: png), png)
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: png)?.tiffRepresentation)
        let converted = try XCTUnwrap(KanbanAttachmentImport.pngData(from: tiff))
        XCTAssertTrue(converted.starts(with: [0x89, 0x50, 0x4E, 0x47]), "PNG signature")
    }

    func testApplyReferencesFilesStoresImagesAndSkipsDuplicates() {
        var attachments = ["/docs/spec.md"]
        let added = KanbanAttachmentImport.apply(
            [.file(URL(fileURLWithPath: "/docs/../docs/spec.md")), .file(URL(fileURLWithPath: "/docs/mock.png")), .image(pngData: png)],
            to: &attachments, cardId: cardId
        )
        XCTAssertEqual(added.count, 2, "\(added)")
        XCTAssertEqual(attachments.count, 3)
        XCTAssertEqual(attachments[1], "/docs/mock.png")
        XCTAssertTrue(KanbanAttachmentStore.isManaged(attachments[2]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachments[2]))
    }

    // MARK: - Pasteboard round trip

    func testPasteboardImageBecomesManagedPNGAndFileStaysReference() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("kanban-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        XCTAssertFalse(KanbanAttachmentImport.hasContent(pasteboard))
        XCTAssertEqual(KanbanAttachmentImport.sources(from: pasteboard), [])

        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        XCTAssertTrue(KanbanAttachmentImport.hasContent(pasteboard))
        let imageSources = KanbanAttachmentImport.sources(from: pasteboard)
        XCTAssertEqual(imageSources, [.image(pngData: png)])

        pasteboard.clearContents()
        let file = tempRoot.appendingPathComponent("picked.txt")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try "x".write(to: file, atomically: true, encoding: .utf8)
        pasteboard.writeObjects([file as NSURL])
        XCTAssertEqual(KanbanAttachmentImport.sources(from: pasteboard), [.file(file)])
    }

    // MARK: - Store hooks

    func testBoardStoreCleansManagedFilesOnUpdateAndRemove() throws {
        let store = KanbanStore(persistence: InMemoryKanbanPersistence())
        var card = KanbanCard(title: "T", requirement: "R", acceptanceCriteria: ["A"], projectRoot: URL(fileURLWithPath: "/tmp/p"), agentId: "claude-code")
        let a = try KanbanAttachmentStore.store(pngData: png, cardId: card.id)
        let b = try KanbanAttachmentStore.store(pngData: png, cardId: card.id, now: Date().addingTimeInterval(1))
        card.attachments = [a, b]
        store.add(card)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b))

        var edited = card
        edited.attachments = [a]
        store.update(edited)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b), "removed reference → managed file deleted")

        store.remove(id: card.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: KanbanAttachmentStore.directory(for: card.id).path))
    }
}
