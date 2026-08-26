//
//  AtollTaskEventListener.swift
//  Atoll
//

import Darwin
import Foundation

final class AtollTaskEventListener {
    static let socketPath = "/tmp/atoll.sock"

    private let onEvent: (TaskEvent) -> Void
    private let queue = DispatchQueue(label: "atoll.task-event-listener", qos: .userInitiated)
    private var serverFileDescriptor: Int32 = -1
    private var isRunning = false

    init(onEvent: @escaping (TaskEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        queue.async { [weak self] in
            self?.run()
        }
    }

    func stop() {
        isRunning = false

        if serverFileDescriptor >= 0 {
            close(serverFileDescriptor)
            serverFileDescriptor = -1
        }

        unlink(Self.socketPath)
    }

    private func run() {
        unlink(Self.socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        serverFileDescriptor = fd

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { pathBytes in
            let utf8Path = Array(Self.socketPath.utf8)
            pathBytes.copyBytes(from: utf8Path.prefix(pathBytes.count - 1))
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0, listen(fd, 8) == 0 else {
            stop()
            return
        }

        while isRunning {
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if isRunning { continue }
                break
            }

            handle(client: client)
            close(client)
        }
    }

    private func handle(client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = Data()

        while isRunning {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }

            pending.append(buffer, count: count)

            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                decode(line)
            }
        }

        if !pending.isEmpty {
            decode(pending)
        }
    }

    private func decode(_ data: Data.SubSequence) {
        let trimmed = Data(data).trimmingASCIIWhitespace()
        guard !trimmed.isEmpty else { return }

        if let event = try? JSONDecoder.atollEventDecoder.decode(TaskEvent.self, from: trimmed) {
            onEvent(event)
        }
    }
}

private extension Data {
    func trimmingASCIIWhitespace() -> Data {
        let whitespace = Set<UInt8>([9, 10, 13, 32])
        guard let start = firstIndex(where: { !whitespace.contains($0) }) else {
            return Data()
        }
        let end = lastIndex(where: { !whitespace.contains($0) }) ?? start
        return Data(self[start...end])
    }
}
