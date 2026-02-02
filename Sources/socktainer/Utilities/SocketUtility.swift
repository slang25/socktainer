import Foundation
import Vapor

public enum UnixSocketError: Error {
    case missingHomeDirectory
}

/// Prepares the Unix socket path by creating the directory and removing any existing socket file.
/// Returns the socket path for use with `configureUnixServer`.
@discardableResult
public func prepareUnixSocket(for app: Application, homeDirectory: String? = nil) throws -> String {
    guard let homeDir = homeDirectory else {
        throw UnixSocketError.missingHomeDirectory
    }

    let fileManager = FileManager.default
    let socketDirectory = "\(homeDir)/.socktainer"
    let socketPath = "\(socketDirectory)/container.sock"

    if !fileManager.fileExists(atPath: socketDirectory) {
        try fileManager.createDirectory(atPath: socketDirectory, withIntermediateDirectories: true)
    }

    if fileManager.fileExists(atPath: socketPath) {
        try fileManager.removeItem(atPath: socketPath)
    }

    return socketPath
}

/// Configures the application's HTTP server to listen on the Unix socket.
public func configureUnixServer(for app: Application, socketPath: String) {
    app.http.server.configuration.hostname = ""
    app.http.server.configuration.port = 0
    app.http.server.configuration.address = .unixDomainSocket(path: socketPath)
}

/// Starts a TCP server on the specified host and port.
/// This runs alongside the Unix socket server for Docker-in-Docker scenarios.
public func startTCPServer(for app: Application, host: String, port: Int) async throws -> HTTPServer {
    // Log security warning for potentially insecure bindings
    if host == "0.0.0.0" {
        app.logger.warning("TCP server binding to 0.0.0.0 - this exposes the Docker API to all network interfaces!")
        app.logger.warning("Consider using --tcp-host 192.168.64.1 (container gateway) or --tcp-host 127.0.0.1 (localhost only)")
    }

    app.logger.info("Starting TCP server on \(host):\(port)")

    var tcpConfiguration = HTTPServer.Configuration(
        hostname: host,
        port: port,
        backlog: 256,
        reuseAddress: true,
        tcpNoDelay: true
    )
    tcpConfiguration.supportVersions = [.one]

    let tcpServer = HTTPServer(
        application: app,
        responder: app.responder.current,
        configuration: tcpConfiguration,
        on: app.eventLoopGroup
    )

    try await tcpServer.start()
    app.logger.info("TCP server listening on \(host):\(port)")

    return tcpServer
}
