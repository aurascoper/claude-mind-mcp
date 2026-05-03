import Foundation

public struct ModelManifest: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let backend: String       // "coreml"
    public let profile: String       // logical profile id, e.g. "minilm-l6-v2"
    public let dim: Int
    public let seq_len: Int
    public let mlpackage: String     // relative path within model dir
    public let tokenizer: String?    // relative path within model dir; nil if model bundles tokenization
    public let sha256: [String: String]
    public let notes: String?

    public init(
        name: String,
        version: String,
        backend: String,
        profile: String,
        dim: Int,
        seq_len: Int,
        mlpackage: String,
        tokenizer: String?,
        sha256: [String: String] = [:],
        notes: String? = nil
    ) {
        self.name = name
        self.version = version
        self.backend = backend
        self.profile = profile
        self.dim = dim
        self.seq_len = seq_len
        self.mlpackage = mlpackage
        self.tokenizer = tokenizer
        self.sha256 = sha256
        self.notes = notes
    }
}
