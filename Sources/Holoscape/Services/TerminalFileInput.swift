import AppKit
import Foundation
import UniformTypeIdentifiers

/// Converts file and bitmap pasteboard payloads into terminal-safe path input.
///
/// File URLs keep their original location. Bitmap-only clipboard payloads (for
/// example, a macOS screenshot copied with Control) are persisted under the
/// process temporary directory so shell and agent CLIs receive a real path.
@MainActor
struct TerminalFileInput {
    static let imageType = NSPasteboard.PasteboardType("public.image")
    static let readableTypes: [NSPasteboard.PasteboardType] = [.fileURL, imageType, .png, .tiff]

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? [])
            .map { $0 as URL }
            .filter(\.isFileURL)
    }

    static func shellQuotedPaths(_ urls: [URL]) -> String {
        urls.map { shellQuote($0.path) }.joined(separator: " ")
    }

    static func inputText(
        from pasteboard: NSPasteboard,
        imageDirectory: URL = defaultImageDirectory
    ) throws -> String? {
        let urls = fileURLs(from: pasteboard)
        if !urls.isEmpty {
            return shellQuotedPaths(urls)
        }

        if let png = pasteboard.data(forType: .png) {
            return shellQuotedPaths([
                try persistImageData(png, fileExtension: "png", in: imageDirectory),
            ])
        }

        if let tiff = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return shellQuotedPaths([
                try persistImageData(png, fileExtension: "png", in: imageDirectory),
            ])
        }

        if let imageData = genericImageData(from: pasteboard),
           let image = NSImage(data: imageData),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return shellQuotedPaths([
                try persistImageData(png, fileExtension: "png", in: imageDirectory),
            ])
        }

        return nil
    }

    private static func genericImageData(from pasteboard: NSPasteboard) -> Data? {
        for type in pasteboard.types ?? [] {
            guard let uniformType = UTType(type.rawValue),
                  uniformType.conforms(to: .image),
                  let data = pasteboard.data(forType: type) else {
                continue
            }
            return data
        }
        return nil
    }

    static func persistImageData(
        _ data: Data,
        fileExtension: String,
        in directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory
            .appendingPathComponent("pasted-image-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try data.write(to: url, options: [.atomic])
        return url
    }

    private static var defaultImageDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Holoscape", isDirectory: true)
            .appendingPathComponent("Pasted Images", isDirectory: true)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
