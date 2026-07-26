import Darwin
import Dispatch
import Foundation

package enum LifecycleHookInput {
    package static let maximumBytes = 64_000

    package static func readUTF8(from handle: FileHandle) -> String? {
        var data = Data()
        data.reserveCapacity(maximumBytes)

        do {
            while data.count <= maximumBytes {
                let count = min(4_096, maximumBytes + 1 - data.count)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            return nil
        }

        guard !data.isEmpty, data.count <= maximumBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

package enum LifecycleEventDelivery {
    package static func deliver(
        _ event: LifecycleEvent,
        socketPath: String = LifecycleSocketServer.path,
        queue: LifecycleEventQueue = LifecycleEventQueue()
    ) -> Bool {
        LifecycleSocketClient.send(event, path: socketPath) || queue.enqueue(event) != nil
    }
}

package final class LifecycleSocketServer {
    package static let path = FileManager.default.homeDirectoryForCurrentUser
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

    package init(
        queue: LifecycleEventQueue,
        path: String = LifecycleSocketServer.path,
        onReceipt: @escaping @Sendable (QueuedLifecycleEvent) -> Void
    ) {
        self.queue = queue
        socketPath = path
        self.onReceipt = onReceipt
    }

    package func start() throws {
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

    package func stop() {
        readSource?.cancel()
        readSource = nil
        socketFD = -1
        removeOwnedSocketFile()
        ownedSocketIdentity = nil
    }

    private func acceptConnection(from listenerFD: Int32) {
        let clientFD = accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return }
        let queue = queue
        let onReceipt = onReceipt
        DispatchQueue.global(qos: .utility).async {
            Self.handleConnection(clientFD, queue: queue, onReceipt: onReceipt)
        }
    }

    private static func handleConnection(
        _ clientFD: Int32,
        queue: LifecycleEventQueue,
        onReceipt: @escaping @Sendable (QueuedLifecycleEvent) -> Void
    ) {
        defer { close(clientFD) }
        preventSIGPIPE(on: clientFD)
        setReceiveTimeout(on: clientFD)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var reachedEnd = false

        while data.count <= LifecycleHookInput.maximumBytes {
            let remaining = LifecycleHookInput.maximumBytes + 1 - data.count
            let count = read(clientFD, &buffer, min(buffer.count, remaining))
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

        guard reachedEnd,
              !data.isEmpty,
              data.count <= LifecycleHookInput.maximumBytes,
              let text = String(data: data, encoding: .utf8),
              let event = LifecycleEvent.parse(jsonLine: text),
              let receipt = queue.enqueue(event) else {
            _ = writeAll(Data("error\n".utf8), to: clientFD)
            return
        }

        onReceipt(receipt)
        _ = writeAll(Data("ok\n".utf8), to: clientFD)
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

    private static func preventSIGPIPE(on socketFD: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout.size(ofValue: enabled))
        )
    }

    private static func setReceiveTimeout(on socketFD: Int32, milliseconds: Int32 = 500) {
        var timeout = timeval(
            tv_sec: Int(milliseconds / 1_000),
            tv_usec: Int32(milliseconds % 1_000) * 1_000
        )
        _ = setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
    }

    private static func writeAll(_ data: Data, to socketFD: Int32) -> Bool {
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

package enum LifecycleSocketClient {
    private static let deadlineMilliseconds: Int32 = 500

    package static func send(
        _ event: LifecycleEvent,
        path: String = LifecycleSocketServer.path
    ) -> Bool {
        guard let line = event.jsonLine()?.appending("\n"),
              let data = line.data(using: .utf8),
              data.count <= LifecycleHookInput.maximumBytes else {
            return false
        }

        let deadline = MonotonicDeadline(milliseconds: deadlineMilliseconds)
        guard let socketFD = connectedSocket(path: path, deadline: deadline) else {
            return false
        }
        defer { close(socketFD) }

        guard writeAll(data, to: socketFD, deadline: deadline),
              shutdownWrite(socketFD, deadline: deadline) else {
            return false
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16)
        while response.count < 32, !deadline.hasExpired {
            let count = read(socketFD, &buffer, min(buffer.count, 32 - response.count))
            if count > 0 {
                response.append(contentsOf: buffer.prefix(Int(count)))
                if response.contains(0x0A) { break }
                continue
            }
            if count == 0 { return false }
            if errno == EINTR { continue }
            guard (errno == EAGAIN || errno == EWOULDBLOCK),
                  wait(for: Int16(POLLIN), on: socketFD, until: deadline) else {
                return false
            }
        }
        return response == Data("ok\n".utf8)
    }

    package static func canConnect(
        path: String = LifecycleSocketServer.path,
        timeoutMilliseconds: Int32 = 250
    ) -> Bool {
        let deadline = MonotonicDeadline(milliseconds: min(max(1, timeoutMilliseconds), deadlineMilliseconds))
        guard let socketFD = connectedSocket(path: path, deadline: deadline) else {
            return false
        }
        close(socketFD)
        return true
    }

    private static func connectedSocket(
        path: String,
        deadline: MonotonicDeadline
    ) -> Int32? {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }
        preventSIGPIPE(on: socketFD)

        do {
            let flags = fcntl(socketFD, F_GETFL, 0)
            guard flags >= 0, fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
                close(socketFD)
                return nil
            }

            var address = try socketAddress(path: path)
            let length = socketAddressLength(path: path)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socketFD, $0, length)
                }
            }
            if connected != 0 {
                guard errno == EINPROGRESS || errno == EALREADY || errno == EINTR,
                      wait(for: Int16(POLLOUT), on: socketFD, until: deadline) else {
                    close(socketFD)
                    return nil
                }

                var socketError: Int32 = 0
                var socketErrorLength = socklen_t(MemoryLayout.size(ofValue: socketError))
                guard getsockopt(
                    socketFD,
                    SOL_SOCKET,
                    SO_ERROR,
                    &socketError,
                    &socketErrorLength
                ) == 0,
                    socketError == 0 else {
                    close(socketFD)
                    return nil
                }
            }
            return socketFD
        } catch {
            close(socketFD)
            return nil
        }
    }

    private static func writeAll(
        _ data: Data,
        to socketFD: Int32,
        deadline: MonotonicDeadline
    ) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                guard !deadline.hasExpired else { return false }
                let count = write(socketFD, baseAddress.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                guard count < 0,
                      (errno == EAGAIN || errno == EWOULDBLOCK),
                      wait(for: Int16(POLLOUT), on: socketFD, until: deadline) else {
                    return false
                }
            }
            return true
        }
    }

    private static func shutdownWrite(
        _ socketFD: Int32,
        deadline: MonotonicDeadline
    ) -> Bool {
        while !deadline.hasExpired {
            if shutdown(socketFD, SHUT_WR) == 0 { return true }
            if errno != EINTR { return false }
        }
        return false
    }

    private static func wait(
        for events: Int16,
        on socketFD: Int32,
        until deadline: MonotonicDeadline
    ) -> Bool {
        while let timeout = deadline.remainingMilliseconds {
            var descriptor = pollfd(fd: socketFD, events: events, revents: 0)
            let result = poll(&descriptor, 1, timeout)
            if result > 0 { return true }
            if result == 0 { return false }
            if errno != EINTR { return false }
        }
        return false
    }

    private static func preventSIGPIPE(on socketFD: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout.size(ofValue: enabled))
        )
    }
}

private struct MonotonicDeadline {
    private let deadline: UInt64

    init(milliseconds: Int32) {
        deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(0, milliseconds)) * 1_000_000
    }

    var hasExpired: Bool {
        DispatchTime.now().uptimeNanoseconds >= deadline
    }

    var remainingMilliseconds: Int32? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return nil }
        let nanoseconds = deadline - now
        return Int32(min(UInt64(Int32.max), (nanoseconds + 999_999) / 1_000_000))
    }
}

private func socketAddress(path: String) throws -> sockaddr_un {
    let length = socketAddressLength(path: path)
    guard length <= MemoryLayout<sockaddr_un>.size,
          length <= UInt8.max else {
        throw POSIXError(.ENAMETOOLONG)
    }

    var address = sockaddr_un()
    address.sun_len = UInt8(length)
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
