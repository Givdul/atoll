import AtollCore
import Darwin
import Foundation

final class LifecycleSocketServer {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".atoll/lifecycle.sock").path

    private let onEvent: @Sendable (LifecycleEvent) -> Void
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    init(onEvent: @escaping @Sendable (LifecycleEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() throws {
        let path = Self.path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: path)

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.ENFILE) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try path.withCString { source in
            let copied = withUnsafeMutableBytes(of: &address.sun_path) { destination in
                strlcpy(destination.baseAddress?.assumingMemoryBound(to: CChar.self), source, destination.count)
            }
            guard copied < MemoryLayout.size(ofValue: address.sun_path) else {
                throw POSIXError(.ENAMETOOLONG)
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, length) }
        }
        guard result == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(socketFD)
            socketFD = -1
            throw error
        }
        guard listen(socketFD, 16) == 0 else { throw POSIXError(.EIO) }
        chmod(path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { [socketFD] in close(socketFD) }
        source.resume()
        readSource = source
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        socketFD = -1
        try? FileManager.default.removeItem(atPath: Self.path)
    }

    private func acceptConnections() {
        let clientFD = accept(socketFD, nil, nil)
        guard clientFD >= 0 else { return }
        defer { close(clientFD) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count < 64_000 {
            let count = read(clientFD, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }

        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let event = LifecycleEvent.parse(jsonLine: String(line)) else { continue }
            onEvent(event)
        }
    }
}

enum LifecycleSocketClient {
    static func send(_ event: LifecycleEvent, path: String = LifecycleSocketServer.path) -> Bool {
        guard let line = event.jsonLine()?.appending("\n"), let data = line.data(using: .utf8) else {
            return false
        }

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                strlcpy(destination.baseAddress?.assumingMemoryBound(to: CChar.self), source, destination.count)
            }
        }
        guard copied < MemoryLayout.size(ofValue: address.sun_path) else { return false }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, length) }
        }
        guard connected == 0 else { return false }

        return data.withUnsafeBytes { bytes in
            write(socketFD, bytes.baseAddress, bytes.count) == bytes.count
        }
    }
}
