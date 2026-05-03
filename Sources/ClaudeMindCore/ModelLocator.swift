import Foundation
import CryptoKit
import Logging

public enum ModelLocator {
    public struct Resolved: Sendable {
        public let manifest: ModelManifest
        public let dir: URL
        public var modelPath: String { dir.appendingPathComponent(manifest.mlpackage).path }
        public var tokenizerPath: String? { manifest.tokenizer.map { dir.appendingPathComponent($0).path } }
    }

    /// - Parameters:
    ///   - verify: if true, every file listed in `manifest.sha256` must hash
    ///     to the recorded value. Mismatch fails closed: returns `nil` so the
    ///     caller falls back to NL rather than loading a tampered model.
    public static func locate(
        name: String,
        env: [String: String] = ProcessInfo.processInfo.environment,
        cwd: String = FileManager.default.currentDirectoryPath,
        verify: Bool = true,
        logger: Logger? = nil
    ) -> Resolved? {
        var candidates: [URL] = []

        if let custom = env["CLAUDE_MIND_MODELS_DIR"], !custom.isEmpty {
            candidates.append(URL(fileURLWithPath: custom).appendingPathComponent(name))
        }

        let appSupport = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        candidates.append(appSupport.appendingPathComponent("claude-mind/models/\(name)"))

        // Dev fallback: cwd/docs/bench/models/<name>
        candidates.append(URL(fileURLWithPath: cwd).appendingPathComponent("docs/bench/models/\(name)"))

        for dir in candidates {
            let mPath = dir.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: mPath.path) else {
                logger?.debug("ModelLocator: no manifest at \(mPath.path)")
                continue
            }
            do {
                let data = try Data(contentsOf: mPath)
                let manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
                if verify {
                    if let mismatch = verifyChecksums(dir: dir, manifest: manifest, logger: logger) {
                        logger?.error("ModelLocator: manifest verification failed at \(dir.path): \(mismatch). Refusing to load.")
                        continue
                    }
                    logger?.info("ModelLocator: verified \(name) at \(dir.path) (profile=\(manifest.profile) dim=\(manifest.dim) files=\(manifest.sha256.count))")
                } else {
                    logger?.info("ModelLocator: resolved (unverified) \(name) at \(dir.path)")
                }
                return Resolved(manifest: manifest, dir: dir)
            } catch {
                logger?.warning("ModelLocator: manifest at \(mPath.path) failed to decode: \(error)")
            }
        }
        logger?.info("ModelLocator: no usable manifest for \(name); searched \(candidates.map { $0.path })")
        return nil
    }

    /// Returns nil on success; description of the first failed file on mismatch / missing.
    private static func verifyChecksums(dir: URL, manifest: ModelManifest, logger: Logger?) -> String? {
        for (relPath, expected) in manifest.sha256 {
            let url = dir.appendingPathComponent(relPath)
            guard let data = try? Data(contentsOf: url) else {
                return "missing file \(relPath)"
            }
            let h = SHA256.hash(data: data)
            let hex = h.map { String(format: "%02x", $0) }.joined()
            if hex != expected.lowercased() {
                return "sha256 mismatch for \(relPath): got \(hex.prefix(12))… expected \(expected.prefix(12))…"
            }
        }
        return nil
    }
}
