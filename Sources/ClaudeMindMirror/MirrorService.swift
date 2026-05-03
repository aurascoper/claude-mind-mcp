import Foundation
import Logging
import ServiceLifecycle
import ClaudeMindCore

public struct MirrorService: Service {
    let worker: MirrorWorker
    let logger: Logger

    public init(worker: MirrorWorker, logger: Logger) {
        self.worker = worker
        self.logger = logger
    }

    public func run() async throws {
        try await cancelWhenGracefulShutdown {
            try await worker.run()
        }
    }
}
