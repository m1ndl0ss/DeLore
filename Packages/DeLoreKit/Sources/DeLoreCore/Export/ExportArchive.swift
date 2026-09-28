import Foundation

public enum ExportArchiveError: Error, Equatable, Sendable {
    case unreadable
    case unsupportedFormat
    case encryptedArchive
    case entryTooLarge
    case entryNotFound
}

/// Read-only view over an Instagram data export, either an extracted folder or the ZIP.
public protocol ExportArchive: Sendable {
    /// Relative paths using "/" separators.
    func entryPaths() throws -> [String]
    func contents(of path: String) throws -> Data
}

public struct DirectoryExportArchive: ExportArchive {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func entryPaths() throws -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw ExportArchiveError.unreadable
        }
        let rootComponents = root.standardizedFileURL.pathComponents
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "json" {
            let components = url.standardizedFileURL.pathComponents
            guard components.count > rootComponents.count else { continue }
            paths.append(components.dropFirst(rootComponents.count).joined(separator: "/"))
        }
        return paths
    }

    public func contents(of path: String) throws -> Data {
        let url = path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw ExportArchiveError.entryNotFound
        }
        return data
    }
}
