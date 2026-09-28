import Foundation

/// Removes everything sensitive the app keeps on the device: secrets, the imported library,
/// cleanup progress, the cleaned-message ledger and temporary files.
public struct LocalDataEraser: Sendable {
    private let secrets: SecretStore
    private let jobs: JobStore
    private let library: LocalLibraryStore?
    private let extraDirectories: [URL]
    private let preservedSecretKeys: [String]

    /// `preservedSecretKeys` survive the wipe (e.g. purchased-but-unused cleanup passes, which
    /// are the user's property, not sensitive data).
    public init(
        secrets: SecretStore,
        jobs: JobStore,
        library: LocalLibraryStore?,
        extraDirectories: [URL] = [],
        preservedSecretKeys: [String] = []
    ) {
        self.secrets = secrets
        self.jobs = jobs
        self.library = library
        self.extraDirectories = extraDirectories
        self.preservedSecretKeys = preservedSecretKeys
    }

    public func eraseAll() throws {
        var preserved: [String: Data] = [:]
        for key in preservedSecretKeys {
            if let value = try secrets.data(for: key) { preserved[key] = value }
        }
        try secrets.removeAll()
        for (key, value) in preserved { try secrets.set(value, for: key) }

        try jobs.wipe()
        try library?.wipe()
        for directory in extraDirectories {
            try ProtectedFiles.removeItemIfPresent(directory)
        }
    }
}
