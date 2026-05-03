import Foundation
import PostgresNIO

public struct MirrorConfig: Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String?
    public let database: String
    public let useTLS: Bool

    public let pollInterval: Duration
    public let batchSize: Int
    public let backoffMin: Duration
    public let backoffMax: Duration
    public let warnAtPending: Int
    public let warnAtOldestSeconds: TimeInterval

    public init(
        host: String,
        port: Int = 5432,
        username: String,
        password: String? = nil,
        database: String,
        useTLS: Bool = false,
        pollInterval: Duration = .milliseconds(500),
        batchSize: Int = 100,
        backoffMin: Duration = .seconds(1),
        backoffMax: Duration = .seconds(30),
        warnAtPending: Int = 1000,
        warnAtOldestSeconds: TimeInterval = 3600
    ) {
        self.host = host; self.port = port; self.username = username; self.password = password
        self.database = database; self.useTLS = useTLS
        self.pollInterval = pollInterval; self.batchSize = batchSize
        self.backoffMin = backoffMin; self.backoffMax = backoffMax
        self.warnAtPending = warnAtPending; self.warnAtOldestSeconds = warnAtOldestSeconds
    }

    /// Parse a libpq-style DSN: `postgresql://user:pass@host:port/dbname?sslmode=disable`
    public static func parseDSN(_ dsn: String) throws -> MirrorConfig {
        guard let url = URLComponents(string: dsn) else {
            throw MirrorError.badDSN("could not parse \(dsn)")
        }
        guard let host = url.host, !host.isEmpty else { throw MirrorError.badDSN("missing host") }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let database = path.isEmpty ? "postgres" : path
        let sslmode = url.queryItems?.first { $0.name == "sslmode" }?.value ?? "disable"
        return MirrorConfig(
            host: host,
            port: url.port ?? 5432,
            username: url.user ?? "postgres",
            password: url.password,
            database: database,
            useTLS: sslmode != "disable"
        )
    }

    public func postgresClientConfig() throws -> PostgresClient.Configuration {
        // v2.2 ships with TLS=disable; TLS-enabled connections (sslmode=require) are
        // a v2.x follow-up that needs an explicit NIOSSL.TLSConfiguration. For now
        // any sslmode != disable is treated as an error so we don't silently send
        // credentials over plaintext.
        if useTLS {
            throw MirrorError.badDSN("TLS connections are not yet supported in v2.2; use sslmode=disable.")
        }
        return PostgresClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disable
        )
    }
}

public enum MirrorError: Error, CustomStringConvertible {
    case badDSN(String)
    case schemaInit(String)
    case publishFailed(String)
    public var description: String {
        switch self {
        case .badDSN(let s): return "Bad mirror DSN: \(s)"
        case .schemaInit(let s): return "Mirror schema init failed: \(s)"
        case .publishFailed(let s): return "Mirror publish failed: \(s)"
        }
    }
}
