import Foundation
import PostgresNIO
import Logging

/// Minimal connection probe for diagnosing postgres-nio behavior in isolation.
public enum MirrorProbe {
    public static func runProbe(dsn: String, logger: Logger) async throws {
        let cfg = try MirrorConfig.parseDSN(dsn).postgresClientConfig()
        let client = PostgresClient(configuration: cfg, backgroundLogger: logger)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                logger.info("probe: SELECT 1")
                let r1 = try await client.query("SELECT 1")
                for try await _ in r1 {}
                logger.info("probe: SELECT 1 done")

                logger.info("probe: SELECT 2")
                let r2 = try await client.query("SELECT 2")
                for try await _ in r2 {}
                logger.info("probe: SELECT 2 done")

                logger.info("probe: CREATE TABLE")
                let r3 = try await client.query("CREATE TABLE IF NOT EXISTS probe_t (id INT)")
                for try await _ in r3 {}
                logger.info("probe: CREATE TABLE done")

                logger.info("probe: CREATE INDEX")
                let r4 = try await client.query("CREATE INDEX IF NOT EXISTS probe_t_idx ON probe_t (id)")
                for try await _ in r4 {}
                logger.info("probe: CREATE INDEX done")
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
