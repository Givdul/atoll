import AtollCore
import Darwin
import Foundation

final class LifecycleSocketServer {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".atoll/lifecycle.sock").path

    private struct SocketIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private let queue: LifecycleEventQueue
    private let socketPath: String
    private let onReceipt: @Sendable (QueuedLifecycleEvent) -> Void
    private var socketFD: Int32 = -1
    private var ownedSocketIdentity: SocketIdentity?
    private var readSource: DispatchSourceRead?

    init(
        queue: LifecycleEventQueue,
        path: String = LifecycleSocketServer.path,
        onReceipt: @escaping @Sendable (QueuedLifecycleEvent) -> Void
    ) {
        self.queue = queue
        socketPath = path
        self.onReceipt = onReceipt
    }

    func start() throws {
        guard socketFD < 0 else { throw POSIXError(.EALREADY) }

        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try PrivateStorage.ensureDirectory(at: directory)
        try removeStaleSocketIfNeeded()

        let listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { throw currentPOSIXError(fallback: .ENFILE) }

        do {
            var address = try socketAddress(path: socketPath)
            let length = socketAddressLength(path: socketPath)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listenerFD, $0, length)
                }
            }
            guard result == 0 else { throw currentPOSIXError() }

            ownedSocketIdentity = Self.socketIdentity(at: socketPath)
            guard ownedSocketIdentity != nil else { throw POSIXError(.EIO) }
            guard listen(listenerFD, 16) == 0 else { throw currentPOSIXError() }
            try PrivateStorage.hardenFile(at: URL(fileURLWithPath: socketPath))

            socketFD = listenerFD
            let source = DispatchSource.makeReadSource(
                fileDescriptor: listenerFD,
                queue: .global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                self?.acceptConnection(from: listenerFD)
            }
            source.setCancelHandler {
                close(listenerFD)
            }
            source.resume()
            readSource = source
        } catch {
            close(listenerFD)
            removeOwnedSocketFile()
            ownedSocketIdentity = nil
            throw error
        }
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        socketFD = -1
        removeOwnedSocketFile()
        ownedSocketIdentity = nil
    }

    private func acceptConnection(from listenerFD: Int32) {
        let clientFD = accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return }
        defer { close(clientFD) }
        Self.preventSIGPIPE(on: clientFD)
        Self.setReceiveTimeout(on: clientFD)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var reachedEnd = false

        while data.count <= 64_000 {
            let count = read(clientFD, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(Int(count)))
                continue
            }
            if count == 0 {
                reachedEnd = true
                break
            }
            if errno == EINTR { continue }
            break
        }

        guard reachedEnd, !data.isEmpty, data.count <= 64_000,
              let text = String(data: data, encoding: .utf8) else {
            _ = Self.writeAll(Data("error\n".utf8), to: clientFD)
            return
        }

        let lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else {
            _ = Self.writeAll(Data("error\n".utf8), to: clientFD)
            return
        }

        var receipts: [QueuedLifecycleEvent] = []
        for line in lines {
            guard let event = LifecycleEvent.parse(jsonLine: String(line)),
                  let receipt = queue.enqueue(event) else {
                _ = Self.writeAll(Data("error\n".utf8), to: clientFD)
                return
            }
            receipts.append(receipt)
        }

        for receipt in receipts {
            onReceipt(receipt)
        }
        _ = Self.writeAll(Data("ok\n".utf8), to: clientFD)
    }

    private func removeStaleSocketIfNeeded() throws {
        guard let identity = Self.socketIdentity(at: socketPath) else {
            if FileManager.default.fileExists(atPath: socketPath) {
                throw POSIXError(.EEXIST)
            }
            return
        }

        if LifecycleSocketClient.canConnect(path: socketPath) {
            throw POSIXError(.EADDRINUSE)
        }

        guard Self.socketIdentity(at: socketPath) == identity else {
            throw POSIXError(.EAGAIN)
        }
        try FileManager.default.removeItem(atPath: socketPath)
    }

    private func removeOwnedSocketFile() {
        guard let ownedSocketIdentity,
              Self.socketIdentity(at: socketPath) == ownedSocketIdentity else {
            return
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private static func socketIdentity(at path: String) -> SocketIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeSocket,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return SocketIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }

    fileprivate static func preventSIGPIPE(on socketFD: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout.size(ofValue: enabled))
        )
    }

    fileprivate static func setReceiveTimeout(on socketFD: Int32, seconds: Int = 5) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
    }

    fileprivate static func writeAll(_ data: Data, to socketFD: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = write(socketFD, baseAddress.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

enum LifecycleSocketClient {
    static func send(_ event: LifecycleEvent, path: String = LifecycleSocketServer.path) -> Bool {
        guard let line = event.jsonLine()?.appending("\n"),
              let data = line.data(using: .utf8),
              let socketFD = connectedSocket(path: path) else {
            return false
        }
        defer { close(socketFD) }
        LifecycleSocketServer.setReceiveTimeout(on: socketFD, seconds: 2)

        guard LifecycleSocketServer.writeAll(data, to: socketFD),
              shutdown(socketFD, SHUT_WR) == 0 else {
            return false
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16)
        while response.count < 32 {
            let count = read(socketFD, &buffer, buffer.count)
            if count > 0 {
                response.append(contentsOf: buffer.prefix(Int(count)))
                if response.contains(0x0A) { break }
                continue
            }
            if count < 0, errno == EINTR { continue }
            break
        }
        return response == Data("ok\n".utf8)
    }

    fileprivate static func canConnect(path: String) -> Bool {
        guard let socketFD = connectedSocket(path: path) else { return false }
        close(socketFD)
        return true
    }

    private static func connectedSocket(path: String) -> Int32? {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }
        LifecycleSocketServer.preventSIGPIPE(on: socketFD)

        do {
            var address = try socketAddress(path: path)
            let length = socketAddressLength(path: path)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socketFD, $0, length)
                }
            }
            guard connected == 0 else {
                close(socketFD)
                return nil
            }
            return socketFD
        } catch {
            close(socketFD)
            return nil
        }
    }
}

private func socketAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_len = UInt8(socketAddressLength(path: path))
    address.sun_family = sa_family_t(AF_UNIX)
    let copied = path.withCString { source in
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            strlcpy(
                destination.baseAddress?.assumingMemoryBound(to: CChar.self),
                source,
                destination.count
            )
        }
    }
    guard copied < MemoryLayout.size(ofValue: address.sun_path) else {
        throw POSIXError(.ENAMETOOLONG)
    }
    return address
}

private func socketAddressLength(path: String) -> socklen_t {
    socklen_t(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
}

private func currentPOSIXError(fallback: POSIXErrorCode = .EIO) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? fallback)
}
