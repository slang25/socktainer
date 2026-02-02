import ArgumentParser
import BuildInfo
import Foundation
import Vapor

// CLI options
struct CLIOptions: ParsableArguments {
    @ArgumentParser.Flag(name: .long, help: "Show version")
    var version: Bool = false

    @ArgumentParser.Flag(name: .long, inversion: .prefixedNo, help: "Check Apple Container compatibility and exit")
    var checkCompatibility: Bool = true

    @ArgumentParser.Flag(name: .long, inversion: .prefixedNo, help: "Enable TCP listener for Docker-in-Docker support")
    var tcp: Bool = false

    @ArgumentParser.Option(name: .long, help: "TCP port")
    var tcpPort: Int = 2375

    @ArgumentParser.Option(name: .long, help: "TCP bind address (0.0.0.0 for Docker-in-Docker support)")
    var tcpHost: String = "0.0.0.0"

    @ArgumentParser.Flag(name: .long, help: "Auto-inject host.containers.internal into container labels")
    var injectHostname: Bool = false
}

// Storage key for accessing CLI options from routes
struct CLIOptionsKey: StorageKey {
    typealias Value = CLIOptions
}

// Parse CLI before starting the app
let options = CLIOptions.parseOrExit()

if options.version {
    print("socktainer: \(getBuildVersion()) (git commit: \(getBuildGitCommit()))")
    exit(0)
}

if options.checkCompatibility {
    await AppleContainerVersionCheck.performCompatibilityCheck()
}

// Ignore real CLI args for Vapor: always behave like `socktainer serve`
let executable = CommandLine.arguments.first ?? "socktainer"
let vaporArgs = [executable, "serve"]

// Detect environment and set up logging
var env = try Environment.detect(arguments: vaporArgs)
try LoggingSystem.bootstrap(from: &env)

// Create and configure the Vapor application
let app = try await Application.make(env)

// Store CLI options in app storage for route access
app.storage[CLIOptionsKey.self] = options

// Prepare Unix socket
let socketPath = try prepareUnixSocket(for: app, homeDirectory: ProcessInfo.processInfo.environment["HOME"])

try await configure(app)

// Start TCP server for Docker-in-Docker support (if enabled)
var tcpServer: HTTPServer?
if options.tcp {
    tcpServer = try await startTCPServer(for: app, host: options.tcpHost, port: options.tcpPort)
}

// Configure Unix socket AFTER TCP server to ensure app.execute() uses the right config
configureUnixServer(for: app, socketPath: socketPath)

// Start the app (Unix socket server)
try await app.execute()

// Shutdown TCP server if running
if let server = tcpServer {
    let shutdown: () async -> Void = server.shutdown
    await shutdown()
}
