import AppKit
import Foundation

@MainActor
final class SharingService: NSObject {
    enum SharingError: LocalizedError {
        case alreadyPresenting
        case emptySelection
        case emptyPayload(String)
        case unsupportedItem(String)
        case invalidURL(String)
        case missingFile(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .alreadyPresenting:
                "The Share menu is already open."
            case .emptySelection:
                "Select at least one item to share."
            case let .emptyPayload(title):
                "\u{201c}\(title)\u{201d} has no content to share."
            case let .unsupportedItem(title):
                "\u{201c}\(title)\u{201d} does not contain a supported share format."
            case let .invalidURL(title):
                "\u{201c}\(title)\u{201d} contains an invalid URL."
            case let .missingFile(path):
                "The original file is no longer available: \(path)"
            case .cancelled:
                "Sharing was cancelled."
            }
        }
    }

    private static let exportRootName = "Pastrix-Sharing"
    private static let staleExportAge: TimeInterval = 24 * 60 * 60

    private var picker: NSSharingServicePicker?
    private var shareMenu: NSMenu?
    private var selectedService: NSSharingService?
    private var exportDirectory: URL?

    private(set) var isPresenting = false
    var onFinished: ((Result<Void, Error>) -> Void)?

    override init() {
        super.init()
        Self.removeStaleExports()
    }

    func share(_ clips: [Clip], from _: NSView) throws {
        guard !isPresenting else { throw SharingError.alreadyPresenting }
        guard !clips.isEmpty else { throw SharingError.emptySelection }

        Self.removeStaleExports()
        let directory = Self.exportRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let items: [Any]
        do {
            items = try Self.shareItems(for: clips, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        let menu = NSMenu()
        menu.addItem(picker.standardShareMenuItem)
        self.picker = picker
        shareMenu = menu
        exportDirectory = directory
        isPresenting = true

        // A context-menu command is delivered after mouseDown, while
        // NSSharingServicePicker.show(relativeTo:of:preferredEdge:) is only
        // supported during mouseDown. The standard item owns AppKit's native
        // presentation path, so invoke it after the originating menu closes.
        DispatchQueue.main.async { [weak self, weak menu] in
            guard let self, self.isPresenting, self.picker === picker,
                  let menu, !menu.items.isEmpty else { return }
            menu.performActionForItem(at: 0)
        }
    }

    static func shareItems(for clips: [Clip], directory: URL) throws -> [Any] {
        guard !clips.isEmpty else { throw SharingError.emptySelection }

        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        var exportedFiles: [URL] = []
        do {
            var result: [Any] = []
            for clip in clips {
                guard !clip.payload.items.isEmpty else {
                    throw SharingError.emptyPayload(clip.displayTitle)
                }
                for representations in clip.payload.items {
                    guard !representations.isEmpty else {
                        throw SharingError.emptyPayload(clip.displayTitle)
                    }
                    result.append(try shareItem(
                        for: clip,
                        representations: representations,
                        directory: directory,
                        exportedFiles: &exportedFiles
                    ))
                }
            }
            guard !result.isEmpty else { throw SharingError.emptySelection }
            return result
        } catch {
            for url in exportedFiles { try? manager.removeItem(at: url) }
            throw error
        }
    }

    private static func shareItem(
        for clip: Clip,
        representations: [ClipRepresentation],
        directory: URL,
        exportedFiles: inout [URL]
    ) throws -> Any {
        if let representation = representation(.fileURL, in: representations) {
            let url = try decodedURL(from: representation.data, title: clip.displayTitle)
            guard url.isFileURL else { throw SharingError.invalidURL(clip.displayTitle) }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SharingError.missingFile(url.path)
            }
            return url as NSURL
        }

        if let representation = representation(.pdf, in: representations) {
            return try export(
                representation.data,
                extension: "pdf",
                directory: directory,
                exportedFiles: &exportedFiles
            ) as NSURL
        }
        if let representation = representation(.png, in: representations) {
            return try export(
                representation.data,
                extension: "png",
                directory: directory,
                exportedFiles: &exportedFiles
            ) as NSURL
        }
        if let representation = representation(.tiff, in: representations) {
            return try export(
                representation.data,
                extension: "tiff",
                directory: directory,
                exportedFiles: &exportedFiles
            ) as NSURL
        }

        if clip.kind == .link {
            if let representation = representation(.URL, in: representations) {
                return try decodedURL(from: representation.data, title: clip.displayTitle) as NSURL
            }
            if let representation = representation(.string, in: representations),
               let value = String(data: representation.data, encoding: .utf8),
               let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.scheme != nil {
                return url as NSURL
            }
            throw SharingError.invalidURL(clip.displayTitle)
        }

        if let representation = representation(.string, in: representations),
           let value = String(data: representation.data, encoding: .utf8) {
            return value as NSString
        }

        if let representation = representation(.URL, in: representations) {
            return try decodedURL(from: representation.data, title: clip.displayTitle) as NSURL
        }

        throw SharingError.unsupportedItem(clip.displayTitle)
    }

    private static func representation(
        _ type: NSPasteboard.PasteboardType,
        in representations: [ClipRepresentation]
    ) -> ClipRepresentation? {
        representations.first { $0.type == type.rawValue }
    }

    private static func decodedURL(from data: Data, title: String) throws -> URL {
        guard let value = String(data: data, encoding: .utf8),
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil else {
            throw SharingError.invalidURL(title)
        }
        return url
    }

    private static func export(
        _ data: Data,
        extension pathExtension: String,
        directory: URL,
        exportedFiles: inout [URL]
    ) throws -> URL {
        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try data.write(to: url, options: .atomic)
        exportedFiles.append(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static var exportRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(exportRootName, isDirectory: true)
    }

    private static func removeStaleExports() {
        let manager = FileManager.default
        let root = exportRoot
        guard let entries = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-staleExportAge)
        for entry in entries {
            let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified < cutoff { try? manager.removeItem(at: entry) }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let callback = onFinished
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
        exportDirectory = nil
        selectedService = nil
        shareMenu = nil
        picker = nil
        isPresenting = false
        callback?(result)
    }
}

@MainActor
extension SharingService: @preconcurrency NSSharingServicePickerDelegate {
    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        selectedService = sharingService
        return self
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        if service == nil { finish(.failure(SharingError.cancelled)) }
    }
}

@MainActor
extension SharingService: NSSharingServiceDelegate {
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish(.success(()))
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: any Error
    ) {
        finish(.failure(error))
    }
}
