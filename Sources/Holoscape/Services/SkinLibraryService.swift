import Foundation

/// User-facing failures from the skin library management boundary.
enum SkinLibraryError: Error, Equatable, LocalizedError {
    case invalidName(String)
    case duplicateName(String)
    case sourceMissing(String)
    case invalidSource(String)
    case destinationFailure(String)
    case validationFailure(String)
    case notUserManaged(String)
    case unsafePath(String)
    case activeSkin(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let name): return "The skin name '\(name)' is not valid."
        case .duplicateName(let name): return "A skin or filesystem entry named '\(name)' already exists."
        case .sourceMissing(let name): return "The source skin '\(name)' could not be found."
        case .invalidSource(let name): return "The source skin '\(name)' is invalid or unreadable."
        case .destinationFailure(let reason): return "The skin could not be written: \(reason)"
        case .validationFailure(let reason): return "The new skin failed validation: \(reason)"
        case .notUserManaged(let name): return "'\(name)' is not a user-managed directory skin."
        case .unsafePath(let name): return "The skin path for '\(name)' is unsafe."
        case .activeSkin(let name): return "The active skin '\(name)' cannot be deleted."
        }
    }
}

/// Safe filesystem/domain operations for skins created and managed in-app.
@MainActor
final class SkinLibraryService {
    enum CreationSource: Equatable {
        case starter
        case existing(String)
    }

    private let engine: SkinEngine
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    init(engine: SkinEngine, fileManager: FileManager = .default) {
        self.engine = engine
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func create(name: String, from source: CreationSource = .starter) throws -> URL {
        try validateName(name)
        try ensureDestinationIsFree(name)

        let staging = engine.skinsDirectory
            .appendingPathComponent(".\(name).staging-\(UUID().uuidString)", isDirectory: true)
        let destination = engine.skinsDirectory.appendingPathComponent(name, isDirectory: true)
        var stagingExists = false

        do {
            try fileManager.createDirectory(at: engine.skinsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            stagingExists = true

            switch source {
            case .starter:
                try writeStarterManifest(to: staging, name: name)
            case .existing(let sourceName):
                guard isSafePathComponent(sourceName), sourceName != "Default" else {
                    throw SkinLibraryError.invalidSource(sourceName)
                }
                guard let sourceDirectory = engine.resolvedSkinDirectoryForManagement(named: sourceName) else {
                    throw SkinLibraryError.sourceMissing(sourceName)
                }
                guard isApprovedSourceDirectory(sourceDirectory) else {
                    throw SkinLibraryError.unsafePath(sourceName)
                }
                try rejectSymlinks(in: sourceDirectory, sourceName: sourceName)
                guard engine.loadSkinDefinition(from: sourceDirectory) != nil else {
                    throw SkinLibraryError.invalidSource(sourceName)
                }
                try copyDirectoryContents(from: sourceDirectory, to: staging)
                try rewriteManifestName(in: staging, to: name)
            }

            guard let definition = engine.loadSkinDefinition(from: staging) else {
                throw SkinLibraryError.validationFailure("skin.json could not be decoded")
            }
            guard definition.name == name else {
                throw SkinLibraryError.validationFailure("skin.json has an unexpected name")
            }

            let validated: LoadedSkin
            do {
                validated = try engine.loadComposite(from: staging, name: name)
            } catch {
                throw SkinLibraryError.validationFailure(error.localizedDescription)
            }
            engine.unregisterFonts(validated.fonts)
            try synchronizeManifest(in: staging)

            // Re-check immediately before the non-overwriting atomic move.
            try ensureDestinationIsFree(name)
            try fileManager.moveItem(at: staging, to: destination)
            stagingExists = false
            return destination
        } catch let error as SkinLibraryError {
            if stagingExists { try cleanupStaging(staging, after: error.localizedDescription) }
            throw error
        } catch {
            if stagingExists { try cleanupStaging(staging, after: error.localizedDescription) }
            throw SkinLibraryError.destinationFailure(error.localizedDescription)
        }
    }

    /// Returns the resolved skin directory, including bundled skins and
    /// extracted bundle sources, for a UI reveal action.
    func revealURL(for name: String) throws -> URL {
        guard isSafePathComponent(name), name != "Default" else { throw SkinLibraryError.notUserManaged(name) }
        guard let url = engine.resolvedSkinDirectoryForManagement(named: name) else {
            throw SkinLibraryError.sourceMissing(name)
        }
        return url
    }

    func isUserManaged(name: String) -> Bool {
        guard name != "Default" else { return false }
        let url = engine.skinsDirectory.appendingPathComponent(name, isDirectory: true)
        return isSafeUserDirectory(url)
    }

    func delete(name: String, activeSkinName: String?) throws {
        if name.caseInsensitiveCompare(activeSkinName ?? "") == .orderedSame {
            throw SkinLibraryError.activeSkin(name)
        }
        guard name != "Default" else { throw SkinLibraryError.notUserManaged(name) }
        let url = engine.skinsDirectory.appendingPathComponent(name, isDirectory: true)
        guard isSafeUserDirectory(url) else {
            if !isSafePathComponent(name) { throw SkinLibraryError.unsafePath(name) }
            throw SkinLibraryError.notUserManaged(name)
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw SkinLibraryError.destinationFailure(error.localizedDescription)
        }
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              isSafePathComponent(name), name.caseInsensitiveCompare("Default") != .orderedSame else {
            throw SkinLibraryError.invalidName(name)
        }
    }

    private func isSafePathComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\") else { return false }
        return !name.contains(":")
    }

    private func ensureDestinationIsFree(_ name: String) throws {
        if engine.availableSkins().contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw SkinLibraryError.duplicateName(name)
        }
        let entries: [URL]
        guard fileManager.fileExists(atPath: engine.skinsDirectory.path) else { return }
        do {
            entries = try fileManager.contentsOfDirectory(at: engine.skinsDirectory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            throw SkinLibraryError.destinationFailure(error.localizedDescription)
        }
        if entries.contains(where: { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }) {
            throw SkinLibraryError.duplicateName(name)
        }
    }

    private func writeStarterManifest(to directory: URL, name: String) throws {
        let starter = SkinDefinition(
            windowBackground: "#10151d",
            titleBarBackground: "#182331",
            sidebarBackground: "#121b27",
            tabActiveColor: "#8de7ff",
            tabInactiveColor: "#75879b",
            textForeground: "#e7f2f8",
            ansiColors: ["#10151d", "#ff6b7a", "#8be28b", "#ffd166", "#78b7ff", "#d19cff", "#66d9e8", "#e7f2f8", "#526273", "#ff9aa5", "#a8f0a8", "#ffe29a", "#a8d0ff", "#e4c2ff", "#a5edf5", "#ffffff"],
            version: "2.0",
            name: name,
            author: "Holoscape",
            description: "A clean, modern dark workspace with cool blue surfaces and high-contrast readable type.",
            surfaces: [
                "window.background": SurfaceDescriptor(fill: .gradient(direction: .vertical, stops: [.init(offset: 0, color: "#10151d"), .init(offset: 1, color: "#1a2735")])),
                "tabBar.container": SurfaceDescriptor(fill: .color("#182331"), border: .init(color: "#33495d", width: 1), corner: .uniform(10)),
                "tabBar.tab.active": SurfaceDescriptor(fill: .color("#24485b"), corner: .uniform(8), font: .init(family: "SF Pro", size: 13, weight: "semibold"), text: .init(color: "#e7f2f8", shadow: nil)),
                "tabBar.tab.normal": SurfaceDescriptor(fill: .color("#182331"), corner: .uniform(8), font: .init(family: "SF Pro", size: 13, weight: "medium"), text: .init(color: "#9db0c3", shadow: nil)),
                "sidebar.container": SurfaceDescriptor(fill: .color("#121b27")),
                "sidebar.row.normal": SurfaceDescriptor(font: .init(family: "SF Pro", size: 13, weight: "regular"), text: .init(color: "#c5d4df", shadow: nil)),
                "sidebar.row.selected": SurfaceDescriptor(fill: .color("#24485b"), corner: .uniform(8), font: .init(family: "SF Pro", size: 13, weight: "semibold"), text: .init(color: "#ffffff", shadow: nil)),
                "inputBox.container": SurfaceDescriptor(fill: .color("#0c1118"), border: .init(color: "#2b3d4e", width: 1), corner: .uniform(12), padding: .init(top: 10, right: 12, bottom: 10, left: 12)),
                "inputBox.field": SurfaceDescriptor(fill: .color("#101923"), corner: .uniform(9), font: .init(family: "SF Mono", size: 13, weight: "regular"), text: .init(color: "#e7f2f8", shadow: nil)),
                "sessionLauncher.container": SurfaceDescriptor(fill: .color("#111b26"), border: .init(color: "#33495d", width: 1), corner: .uniform(14)),
                "sessionLauncher.row": SurfaceDescriptor(corner: .uniform(8), font: .init(family: "SF Pro", size: 13, weight: "medium"), text: .init(color: "#e7f2f8", shadow: nil)),
                "settings.panel": SurfaceDescriptor(fill: .color("#121b27"), border: .init(color: "#2b3d4e", width: 1), corner: .uniform(14))
            ]
        )
        let data = try encoder.encode(starter)
        try data.write(to: directory.appendingPathComponent("skin.json"), options: .atomic)
    }

    private func rewriteManifestName(in directory: URL, to name: String) throws {
        let manifestURL = directory.appendingPathComponent("skin.json")
        do {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
            guard var manifest = object else { throw SkinLibraryError.invalidSource(directory.lastPathComponent) }
            manifest["name"] = name
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: manifestURL, options: .atomic)
        } catch let error as SkinLibraryError { throw error }
        catch { throw SkinLibraryError.invalidSource(directory.lastPathComponent) }
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let entries = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for entry in entries {
            try fileManager.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
        }
    }

    private func isApprovedSourceDirectory(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return engine.approvedSkinSourceRoots.contains { root in
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            return resolved != resolvedRoot && resolved.hasPrefix(resolvedRoot + "/")
        }
    }

    private func rejectSymlinks(in root: URL, sourceName: String) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SkinLibraryError.invalidSource(sourceName)
        }
        if try fileType(at: root) == .typeSymbolicLink {
            throw SkinLibraryError.unsafePath(sourceName)
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch {
            throw SkinLibraryError.invalidSource(sourceName)
        }
        for entry in entries {
            if try fileType(at: entry) == .typeSymbolicLink {
                throw SkinLibraryError.invalidSource(sourceName)
            }
            var childIsDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: entry.path, isDirectory: &childIsDirectory), childIsDirectory.boolValue {
                try rejectSymlinks(in: entry, sourceName: sourceName)
            }
        }
    }

    private func fileType(at url: URL) throws -> FileAttributeType {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType else {
                throw SkinLibraryError.invalidSource(url.lastPathComponent)
            }
            return type
        } catch let error as SkinLibraryError {
            throw error
        } catch {
            throw SkinLibraryError.invalidSource(url.lastPathComponent)
        }
    }

    private func synchronizeManifest(in directory: URL) throws {
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: directory.appendingPathComponent("skin.json")) }
        catch { throw SkinLibraryError.destinationFailure(error.localizedDescription) }
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            let synchronizationError = error.localizedDescription
            do {
                try handle.close()
            } catch {
                throw SkinLibraryError.destinationFailure(
                    "\(synchronizationError); closing skin.json also failed: \(error.localizedDescription)"
                )
            }
            throw SkinLibraryError.destinationFailure(synchronizationError)
        }
    }

    private func cleanupStaging(_ staging: URL, after originalFailure: String) throws {
        do {
            try fileManager.removeItem(at: staging)
        } catch {
            throw SkinLibraryError.destinationFailure(
                "\(originalFailure); staging cleanup also failed: \(error.localizedDescription)"
            )
        }
    }

    private func isSafeResolvedDirectory(_ url: URL) -> Bool {
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = engine.skinsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedPath != rootPath && resolvedPath.hasPrefix(rootPath + "/")
    }

    private func isSafeUserDirectory(_ url: URL) -> Bool {
        let rootPath = engine.skinsDirectory.standardizedFileURL.path
        let candidate = url.standardizedFileURL
        let candidatePath = candidate.path
        guard isSafePathComponent(url.lastPathComponent),
              candidatePath.hasPrefix(rootPath + "/"),
              candidatePath != rootPath,
              isSafeResolvedDirectory(candidate) else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidatePath, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        var isManifestDirectory: ObjCBool = false
        let manifest = candidate.appendingPathComponent("skin.json")
        return fileManager.fileExists(atPath: manifest.path, isDirectory: &isManifestDirectory) && !isManifestDirectory.boolValue
    }
}
