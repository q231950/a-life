import Foundation
import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        // Adding an agent to the cast needs nothing else of the server.
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.first == AddAgent.command {
            exit(AddAgent.main(Array(arguments.dropFirst())))
        }

        var environment = try Environment.detect()
        try LoggingSystem.bootstrap(from: &environment)
        let app = try await Application.make(environment)
        do {
            try await configure(app)
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
