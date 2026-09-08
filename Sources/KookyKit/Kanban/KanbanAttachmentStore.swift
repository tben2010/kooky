import AppKit
import Foundation
import UniformTypeIdentifiers

/// Files Kooky itself created for a card — screenshots pasted from the
/// clipboard or dropped as image data — live under
/// `<dataDirectory>/attachments/<card-id>/`. They are "managed": removing
/// the attachment (or the card) deletes the file, whereas a file the user
/// picked with the open panel is only ever referenced.
///
/// The card model stays path-only; managed-ness is a prefix check, so
/// board.json, the drafter and the launch prompt need no new field.
@MainActor
enum KanbanAttachmentStore {
    /// Test seam — the suite points this at a temp folder; nil = beside
    /// board.json (so `KOOKY_DATA_DIR` applies to attachments too).
    static var rootOverride: URL?

    static var root: URL {
        rootOverride ?? AppPersistence.dataDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    static func directory(for cardId: UUID) -> URL {
        root.appendingPathComponent(cardId.uuidString, isDirectory: true)
    }

    /// True when Kooky owns the file (and so may delete it).
    static func isManaged(_ path: String) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidate.hasPrefix(rootPath + "/")
    }

    /// Writes `pngData` as `screenshot-<timestamp>.png` (a counter suffix
    /// on collision) into the card's folder and returns the absolute path.
    static func store(pngData: Data, cardId: UUID, now: Date = Date()) throws -> String {
        let directory = directory(for: cardId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: now)
        var url = directory.appendingPathComponent("screenshot-\(stamp).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("screenshot-\(stamp)-\(counter).png")
            counter += 1
        }
        try pngData.write(to: url, options: .atomic)
        return KanbanCard.attachmentPath(for: url)
    }

    /// Deletes every managed file of the card that isn't in `attachments`
    /// any more — called with the saved card's list on save, with the
    /// original list when an edit is cancelled. Removes the folder once
    /// it's empty so Application Support doesn't collect husks.
    static func removeOrphans(cardId: UUID, keeping attachments: [String]) {
        let directory = directory(for: cardId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let kept = Set(attachments.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for name in names {
            let url = directory.appendingPathComponent(name)
            if !kept.contains(url.standardizedFileURL.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The card is gone: so is its folder.
    static func removeAll(cardId: UUID) {
        try? FileManager.default.removeItem(at: directory(for: cardId))
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}

/// What the clipboard or a drop hands the editor, reduced to the two
/// shapes the attachment list can take: a file that already exists
/// somewhere (referenced as-is) or raw image bytes (stored as a managed
/// PNG). Pure functions on top so the decision is testable without a
/// live `NSPasteboard`.
@MainActor
enum KanbanAttachmentImport {
    enum Source: Equatable, Sendable {
        case file(URL)
        case image(pngData: Data)
    }

    /// Files win over image data: copying a PNG in Finder puts both a file
    /// URL and the image on the pasteboard, and the user means the file.
    nonisolated static func sources(fileURLs: [URL], imageData: Data?) -> [Source] {
        let files = fileURLs.filter { $0.isFileURL }
        if !files.isEmpty {
            return files.map { .file($0) }
        }
        if let imageData, let png = pngData(from: imageData) {
            return [.image(pngData: png)]
        }
        return []
    }

    /// Applies `sources` to a card draft: files by path, images stored
    /// under the card's folder. Returns the paths that were added (already
    /// present paths are skipped, so pasting twice doesn't duplicate).
    @discardableResult
    static func apply(_ sources: [Source], to attachments: inout [String], cardId: UUID, now: Date = Date()) -> [String] {
        var added: [String] = []
        for source in sources {
            let path: String
            switch source {
            case .file(let url):
                path = KanbanCard.attachmentPath(for: url)
            case .image(let pngData):
                guard let stored = try? KanbanAttachmentStore.store(pngData: pngData, cardId: cardId, now: now) else { continue }
                path = stored
            }
            guard !attachments.contains(path) else { continue }
            attachments.append(path)
            added.append(path)
        }
        return added
    }

    /// Re-encodes any bitmap data (TIFF from a screenshot, JPEG from a
    /// browser…) as PNG; PNG input passes through untouched.
    nonisolated static func pngData(from data: Data) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Pasteboard

    /// True when a paste would add something — drives the button state.
    static func hasContent(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    static func sources(from pasteboard: NSPasteboard = .general) -> [Source] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var imageData: Data?
        if urls.isEmpty {
            imageData = pasteboard.data(forType: .png)
                ?? pasteboard.data(forType: .tiff)
                ?? (pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage)?.tiffRepresentation
        }
        return sources(fileURLs: urls, imageData: imageData)
    }
}
