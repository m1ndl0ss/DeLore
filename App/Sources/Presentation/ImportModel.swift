import DeLoreCore
import Foundation

/// Imports an Instagram download chosen in Files: figures out who the owner is, then builds
/// the local, content-free library. Runs off the main thread.
@MainActor
@Observable
final class ImportModel: Identifiable {
    enum Phase: Equatable {
        case reading
        case chooseOwner(candidates: [String])
        case importing(progress: Double)
        case finished
        case failed(ImportFailure)
    }

    enum ImportFailure: Equatable {
        case notAnExport
        case noMessages
        case unreadable
        case protectedArchive

        var title: String {
            switch self {
            case .notAnExport: return String(localized: "That doesn't look like an Instagram download")
            case .noMessages: return String(localized: "No DMs in this download")
            case .unreadable: return String(localized: "We couldn't open that file")
            case .protectedArchive: return String(localized: "That file is password-protected")
            }
        }

        var message: String {
            switch self {
            case .notAnExport: return String(localized: "Pick the file Instagram sent you. Make sure you chose the JSON format when you asked for it.")
            case .noMessages: return String(localized: "Ask Instagram for another download and make sure Messages is included.")
            case .unreadable: return String(localized: "Try downloading it again from Instagram, then pick it here.")
            case .protectedArchive: return String(localized: "Pick the original download from Instagram instead.")
            }
        }
    }

    private(set) var phase: Phase = .reading
    private let url: URL
    private let library: LocalLibraryStore
    private let analytics: Analytics
    private var archive: ExportArchive?
    private var accessing = false
    private var work: Task<Void, Never>?
    var onFinished: ((LibraryOverview) -> Void)?

    init(url: URL, library: LocalLibraryStore, analytics: Analytics) {
        self.url = url
        self.library = library
        self.analytics = analytics
    }

    func start() {
        analytics.track(.importStarted)
        accessing = url.startAccessingSecurityScopedResource()
        let url = url
        work = Task { [weak self] in
            do {
                let archive = try await Task.detached(priority: .userInitiated) { () throws -> ExportArchive in
                    try Self.openArchive(at: url)
                }.value
                guard let self else { return }
                self.archive = archive
                let importer = ExportImporter(archive: archive, library: self.library)
                let resolution = try await Task.detached(priority: .userInitiated) {
                    try await importer.resolveOwner()
                }.value
                switch resolution {
                case let .resolved(name):
                    self.runImport(owner: name)
                case let .needsChoice(candidates):
                    self.phase = .chooseOwner(candidates: candidates)
                case .noMessages:
                    self.fail(.notAnExport)
                }
            } catch {
                self?.fail(Self.failure(for: error))
            }
        }
    }

    func chooseOwner(_ name: String) {
        runImport(owner: name)
    }

    func cancel() {
        work?.cancel()
        stopAccessing()
    }

    private func runImport(owner: String) {
        guard let archive else { return fail(.unreadable) }
        phase = .importing(progress: 0)
        let importer = ExportImporter(archive: archive, library: library)
        work = Task { [weak self] in
            do {
                let overview = try await Task.detached(priority: .userInitiated) {
                    try await importer.importLibrary(ownerName: owner) { value in
                        Task { @MainActor in self?.updateProgress(value) }
                    }
                }.value
                guard let self else { return }
                self.stopAccessing()
                self.analytics.track(.importCompleted(size: .init(count: overview.sentByOwner)))
                self.phase = .finished
                self.onFinished?(overview)
            } catch {
                self?.fail(Self.failure(for: error))
            }
        }
    }

    private func updateProgress(_ value: Double) {
        if case .importing = phase { phase = .importing(progress: value) }
    }

    private func fail(_ failure: ImportFailure) {
        stopAccessing()
        analytics.track(.importFailed(reason: failure == .noMessages ? .noMessages : .unreadable))
        phase = .failed(failure)
    }

    private func stopAccessing() {
        if accessing {
            url.stopAccessingSecurityScopedResource()
            accessing = false
        }
    }

    nonisolated private static func openArchive(at url: URL) throws -> ExportArchive {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ExportArchiveError.unreadable
        }
        if isDirectory.boolValue { return DirectoryExportArchive(root: url) }
        guard url.pathExtension.lowercased() == "zip" else { throw ExportArchiveError.unsupportedFormat }
        return try ZipExportArchive(url: url)
    }

    nonisolated private static func failure(for error: Error) -> ImportFailure {
        switch error {
        case ExportImportError.noMessagesFound: return .noMessages
        case ExportArchiveError.encryptedArchive: return .protectedArchive
        case ExportArchiveError.unsupportedFormat: return .notAnExport
        default: return .unreadable
        }
    }
}
