import Darwin
import Foundation
import XCTest
@testable import TopsideCore

final class LifecycleSocketTests: XCTestCase {
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: LifecycleEvent?

        func set(_ event: LifecycleEvent) {
            lock.lock()
            value = event
            lock.unlock()
        }

        var event: LifecycleEvent? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private var directory: URL!
    private var socketDirectory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TopsideLifecycleSocketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketDirectory = URL(fileURLWithPath: "/tmp/atl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: socketDirectory)
    }

    func testHookInputIsBoundedNonemptyUTF8() throws {
        XCTAssertNil(try readHookInput(Data()))
        XCTAssertNil(try readHookInput(Data([0xFF])))
        XCTAssertEqual(
            try readHookInput(Data(repeating: 0x61, count: LifecycleHookInput.maximumBytes))?.utf8.count,
            LifecycleHookInput.maximumBytes
        )
        XCTAssertNil(try readHookInput(
            Data(repeating: 0x61, count: LifecycleHookInput.maximumBytes + 1)
        ))
    }

    func testMissingRefusedAndClosedPeersFailPromptly() throws {
        let event = LifecycleEvent(sessionID: "failure", harness: .codex, kind: .started)
        let missing = socketPath("missing")
        XCTAssertFalse(LifecycleSocketClient.send(event, path: missing))

        let refused = socketPath("refused")
        let refusedFD = try makeListener(path: refused)
        close(refusedFD)
        defer { unlink(refused) }
        XCTAssertFalse(LifecycleSocketClient.send(event, path: refused))

        let closed = try Peer(path: socketPath("closed"), behavior: .closeImmediately)
        defer { closed.stop() }
        let start = ContinuousClock.now
        XCTAssertFalse(LifecycleSocketClient.send(event, path: closed.path))
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(900))
    }

    func testPeerThatNeverReadsUsesTheSharedDeadline() throws {
        try assertPromptFailure(.neverReads)
    }

    func testPeerThatNeverAcknowledgesUsesTheSharedDeadline() throws {
        try assertPromptFailure(.neverAcknowledges)
    }

    func testUnexpectedAcknowledgementFailsPromptly() throws {
        try assertPromptFailure(.unexpectedAcknowledgement)
    }

    func testDeliveryFallsBackOnceToQueueAndIgnoresQueueFailure() throws {
        let event = LifecycleEvent(sessionID: "fallback", harness: .claude, kind: .needsInput)
        let missing = socketPath("fallback")
        let queueHome = directory.appendingPathComponent("queue-home", isDirectory: true)
        let queue = LifecycleEventQueue(homeDirectory: queueHome)

        XCTAssertTrue(LifecycleEventDelivery.deliver(event, socketPath: missing, queue: queue))
        XCTAssertEqual(queue.pendingEvents().map(\.event.sessionID), ["fallback"])

        let blockedHome = directory.appendingPathComponent("blocked-home", isDirectory: true)
        try FileManager.default.createDirectory(at: blockedHome, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blockedHome.appendingPathComponent(".topside"))
        XCTAssertFalse(LifecycleEventDelivery.deliver(
            event,
            socketPath: missing,
            queue: LifecycleEventQueue(homeDirectory: blockedHome)
        ))
    }

    func testLiveSocketCarriesTaskLabelWhileQueueRemainsSanitized() throws {
        let queue = LifecycleEventQueue(
            homeDirectory: directory.appendingPathComponent("live-task-home", isDirectory: true)
        )
        let path = socketPath("live-task")
        let received = DispatchSemaphore(value: 0)
        let receivedEvent = EventBox()
        let server = LifecycleSocketServer(queue: queue, path: path) { receipt in
            receivedEvent.set(receipt.event)
            received.signal()
        }
        try server.start()
        defer { server.stop() }

        let event = LifecycleEvent(
            sessionID: "live-task",
            harness: .codex,
            kind: .started,
            taskLabel: "fresh task"
        )
        XCTAssertTrue(LifecycleSocketClient.send(event, path: path))
        XCTAssertEqual(received.wait(timeout: .now() + 0.5), .success)

        let taskLabel = receivedEvent.event?.taskLabel
        XCTAssertEqual(taskLabel, "fresh task")

        let pending = try XCTUnwrap(queue.pendingEvents().first)
        XCTAssertNil(pending.event.taskLabel)
        let queuedFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent("live-task-home/.topside/lifecycle-events"),
                includingPropertiesForKeys: nil
            ).first
        )
        XCTAssertFalse(String(data: try Data(contentsOf: queuedFile), encoding: .utf8)?.contains("task_label") == true)
    }

    func testServerRejectsMalformedAndOversizedBodiesWithoutPartialDelivery() throws {
        let queue = LifecycleEventQueue(
            homeDirectory: directory.appendingPathComponent("server-home", isDirectory: true)
        )
        let path = socketPath("server")
        let server = LifecycleSocketServer(queue: queue, path: path) { _ in }
        try server.start()
        defer { server.stop() }

        XCTAssertEqual(try sendRaw(Data("{".utf8), path: path), Data("error\n".utf8))
        XCTAssertTrue(queue.pendingEvents().isEmpty)

        let valid = try XCTUnwrap(
            LifecycleEvent(sessionID: "partial", harness: .codex, kind: .started).jsonLine()
        )
        var oversized = Data(valid.utf8)
        oversized.append(0x0A)
        oversized.append(Data(
            repeating: 0x61,
            count: LifecycleHookInput.maximumBytes + 1 - oversized.count
        ))
        XCTAssertEqual(try sendRaw(oversized, path: path), Data("error\n".utf8))
        XCTAssertTrue(queue.pendingEvents().isEmpty)
    }

    func testStalledClientDoesNotBlockFollowingValidClient() throws {
        let queue = LifecycleEventQueue(
            homeDirectory: directory.appendingPathComponent("isolation-home", isDirectory: true)
        )
        let path = socketPath("isolation")
        let received = DispatchSemaphore(value: 0)
        let server = LifecycleSocketServer(queue: queue, path: path) { receipt in
            if receipt.event.sessionID == "second" { received.signal() }
        }
        try server.start()
        defer { server.stop() }

        let stalled = try connectRaw(path: path)
        defer { close(stalled) }

        let start = ContinuousClock.now
        XCTAssertTrue(LifecycleSocketClient.send(
            LifecycleEvent(sessionID: "second", harness: .cursor, kind: .started),
            path: path
        ))
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(900))
        XCTAssertEqual(received.wait(timeout: .now() + 0.1), .success)
        XCTAssertEqual(queue.pendingEvents().map(\.event.sessionID), ["second"])
    }

    func testGeneratedBridgeMasksMissingExecutable() throws {
        let home = directory.appendingPathComponent("missing-executable-home", isDirectory: true)
        let installer = LifecycleHookInstaller(
            homeDirectory: home,
            executablePath: home.appendingPathComponent("missing-topside").path
        )
        try installer.install(agents: [.opencode])

        let result = try run(
            executable: home.appendingPathComponent(".topside/bin/topside-hook"),
            arguments: ["codex", "started"],
            input: hookPayload(sessionID: "missing")
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, Data("{}\n".utf8))
        XCTAssertLessThan(result.duration, .milliseconds(900))
    }

    func testGeneratedBridgeMasksRefusedSocket() throws {
        let home = try makeBridgeRuntimeHome()
        let path = home.appendingPathComponent(".topside/lifecycle.sock").path
        let listenerFD = try makeListener(path: path)
        close(listenerFD)
        defer { unlink(path) }
        try assertGeneratedBridgeFailsOpen(home: home, input: hookPayload(sessionID: "refused"))
    }

    func testGeneratedBridgeMasksWriteBackpressure() throws {
        let home = try makeBridgeRuntimeHome()
        let peer = try Peer(
            path: home.appendingPathComponent(".topside/lifecycle.sock").path,
            behavior: .neverReads
        )
        defer { peer.stop() }
        try assertGeneratedBridgeFailsOpen(
            home: home,
            input: hookPayload(sessionID: String(repeating: "a", count: 60_000))
        )
    }

    func testGeneratedBridgeMasksMissingAcknowledgement() throws {
        let home = try makeBridgeRuntimeHome()
        let peer = try Peer(
            path: home.appendingPathComponent(".topside/lifecycle.sock").path,
            behavior: .neverAcknowledges
        )
        defer { peer.stop() }
        try assertGeneratedBridgeFailsOpen(home: home, input: hookPayload(sessionID: "no-ack"))
    }

    func testGeneratedBridgeMasksUnexpectedAcknowledgement() throws {
        let home = try makeBridgeRuntimeHome()
        let peer = try Peer(
            path: home.appendingPathComponent(".topside/lifecycle.sock").path,
            behavior: .unexpectedAcknowledgement
        )
        defer { peer.stop() }
        try assertGeneratedBridgeFailsOpen(home: home, input: hookPayload(sessionID: "unexpected"))
    }

    func testActualLifecycleEntryPointIsBoundedAndFailOpen() throws {
        let executable = actualExecutable
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), executable.path)

        let home = directory.appendingPathComponent("entry-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = ["CFFIXED_USER_HOME": home.path]
        for invalid in [Data(), Data("{".utf8), Data([0xFF]), hookPayload(totalBytes: 64_001)] {
            let result = try run(
                executable: executable,
                arguments: ["--lifecycle-event", "codex", "started"],
                input: invalid,
                environment: environment
            )
            XCTAssertEqual(result.status, 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".topside").path))

        let exactBoundary = try run(
            executable: executable,
            arguments: ["--lifecycle-event", "codex", "started"],
            input: hookPayload(totalBytes: LifecycleHookInput.maximumBytes),
            environment: environment
        )
        XCTAssertEqual(exactBoundary.status, 0)
        let queue = LifecycleEventQueue(homeDirectory: home)
        XCTAssertEqual(queue.pendingEvents().map(\.event.sessionID), ["entry"])

        for index in 1..<LifecycleEventQueue.maximumPendingEvents {
            XCTAssertNotNil(queue.enqueue(
                LifecycleEvent(sessionID: "entry-\(index)", harness: .codex, kind: .started)
            ))
        }
        let lock = home.appendingPathComponent(".topside/.lifecycle-events.writer.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        defer { flock(descriptor, LOCK_UN) }

        let heldLock = try run(
            executable: executable,
            arguments: ["--lifecycle-event", "codex", "started"],
            input: hookPayload(sessionID: "held-lock"),
            environment: environment
        )
        XCTAssertEqual(heldLock.status, 0)
        XCTAssertLessThan(heldLock.duration, .milliseconds(900))
        let retained = queue.pendingEvents().map(\.event.sessionID)
        XCTAssertEqual(retained.count, LifecycleEventQueue.maximumPendingEvents)
        XCTAssertTrue(retained.contains("entry"))
        XCTAssertFalse(retained.contains("held-lock"))

        let blockedHome = directory.appendingPathComponent("entry-blocked-home", isDirectory: true)
        try FileManager.default.createDirectory(at: blockedHome, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blockedHome.appendingPathComponent(".topside"))
        let queueFailure = try run(
            executable: executable,
            arguments: ["--lifecycle-event", "codex", "started"],
            input: hookPayload(sessionID: "queue-failure"),
            environment: ["CFFIXED_USER_HOME": blockedHome.path]
        )
        XCTAssertEqual(queueFailure.status, 0)
    }

    func testActualLifecycleEntryPointAcceptsInputRequiredAlias() throws {
        let home = directory.appendingPathComponent("input-required-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let result = try run(
            executable: actualExecutable,
            arguments: ["--lifecycle-event", "codex", "input_required"],
            input: hookPayload(sessionID: "needs-input"),
            environment: ["CFFIXED_USER_HOME": home.path]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(
            LifecycleEventQueue(homeDirectory: home).pendingEvents().map(\.event.kind),
            [.needsInput]
        )
    }

    private func readHookInput(_ data: Data) throws -> String? {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return LifecycleHookInput.readUTF8(from: handle)
    }

    private func socketPath(_ label: String) -> String {
        socketDirectory.appendingPathComponent("\(label)-\(UUID().uuidString.prefix(8)).sock").path
    }

    private func assertPromptFailure(_ behavior: Peer.Behavior) throws {
        let peer = try Peer(path: socketPath("\(behavior)"), behavior: behavior)
        let sessionID = behavior == .neverReads ? String(repeating: "a", count: 60_000) : "deadline"
        let start = ContinuousClock.now
        XCTAssertFalse(LifecycleSocketClient.send(
            LifecycleEvent(sessionID: sessionID, harness: .codex, kind: .started),
            path: peer.path
        ))
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(900))
        peer.stop()
    }

    private var actualExecutable: URL {
        Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Topside")
    }

    private func makeBridgeRuntimeHome() throws -> URL {
        let home = socketDirectory.appendingPathComponent("home-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".topside", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    private func assertGeneratedBridgeFailsOpen(home: URL, input: Data) throws {
        let installerHome = directory.appendingPathComponent("bridge-\(UUID().uuidString)", isDirectory: true)
        let installer = LifecycleHookInstaller(
            homeDirectory: installerHome,
            executablePath: actualExecutable.path
        )
        try installer.install(agents: [.opencode])
        let result = try run(
            executable: installerHome.appendingPathComponent(".topside/bin/topside-hook"),
            arguments: ["codex", "started"],
            input: input,
            environment: ["CFFIXED_USER_HOME": home.path]
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, Data("{}\n".utf8))
    }

    private func hookPayload(sessionID: String = "entry") -> Data {
        try! JSONSerialization.data(withJSONObject: ["session_id": sessionID])
    }

    private func hookPayload(totalBytes: Int) -> Data {
        let prefix = Data("{\"session_id\":\"entry\",\"padding\":\"".utf8)
        let suffix = Data("\"}".utf8)
        precondition(totalBytes >= prefix.count + suffix.count)
        var payload = prefix
        payload.append(Data(repeating: 0x61, count: totalBytes - prefix.count - suffix.count))
        payload.append(suffix)
        return payload
    }

    private func sendRaw(_ data: Data, path: String) throws -> Data {
        let socketFD = try connectRaw(path: path)
        defer { close(socketFD) }
        try writeAll(data, to: socketFD)
        XCTAssertEqual(shutdown(socketFD, SHUT_WR), 0)

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = read(socketFD, &buffer, buffer.count)
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Data(buffer.prefix(Int(count)))
    }

    private func connectRaw(path: String) throws -> Int32 {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.ENFILE) }
        var address = try testSocketAddress(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, testSocketAddressLength(path: path))
            }
        }
        guard result == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(socketFD)
            throw error
        }
        return socketFD
    }

    private func writeAll(_ data: Data, to socketFD: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(socketFD, baseAddress.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private func run(
        executable: URL,
        arguments: [String],
        input: Data,
        environment: [String: String] = [:]
    ) throws -> ProcessResult {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { _ in completion.signal() }

        let start = ContinuousClock.now
        try process.run()
        try standardInput.fileHandleForWriting.write(contentsOf: input)
        try standardInput.fileHandleForWriting.close()
        guard completion.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            XCTFail("Process timed out: \(executable.path)")
            return ProcessResult(status: -1, output: Data(), duration: start.duration(to: .now))
        }
        return ProcessResult(
            status: process.terminationStatus,
            output: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            duration: start.duration(to: .now)
        )
    }

    private func makeListener(path: String) throws -> Int32 {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.ENFILE) }
        unlink(path)
        var address = try testSocketAddress(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, testSocketAddressLength(path: path))
            }
        }
        guard result == 0, listen(socketFD, 4) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(socketFD)
            throw error
        }
        return socketFD
    }
}

private struct ProcessResult {
    let status: Int32
    let output: Data
    let duration: Duration
}

private final class Peer {
    enum Behavior: Equatable, Sendable {
        case closeImmediately
        case neverReads
        case neverAcknowledges
        case unexpectedAcknowledgement
    }

    let path: String
    private let listenerFD: Int32
    private let release = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var stopped = false

    init(path: String, behavior: Behavior) throws {
        self.path = path
        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { throw POSIXError(.ENFILE) }
        unlink(path)
        var address = try testSocketAddress(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerFD, $0, testSocketAddressLength(path: path))
            }
        }
        guard result == 0, listen(listenerFD, 1) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(listenerFD)
            throw error
        }
        if behavior == .neverReads {
            var receiveBuffer: Int32 = 1_024
            _ = setsockopt(
                listenerFD,
                SOL_SOCKET,
                SO_RCVBUF,
                &receiveBuffer,
                socklen_t(MemoryLayout.size(ofValue: receiveBuffer))
            )
        }

        let release = release
        let finished = finished
        let acceptedListenerFD = listenerFD
        DispatchQueue.global(qos: .utility).async {
            let clientFD = accept(acceptedListenerFD, nil, nil)
            guard clientFD >= 0 else {
                finished.signal()
                return
            }
            defer {
                close(clientFD)
                finished.signal()
            }
            switch behavior {
            case .closeImmediately:
                return
            case .neverReads:
                _ = release.wait(timeout: .now() + 2)
            case .neverAcknowledges:
                drain(clientFD)
                _ = release.wait(timeout: .now() + 2)
            case .unexpectedAcknowledgement:
                drain(clientFD)
                _ = write(clientFD, "no\n", 3)
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        release.signal()
        _ = finished.wait(timeout: .now() + 1)
        close(listenerFD)
        unlink(path)
    }

    deinit {
        stop()
    }
}

private func drain(_ socketFD: Int32) {
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = read(socketFD, &buffer, buffer.count)
        if count > 0 { continue }
        if count < 0, errno == EINTR { continue }
        return
    }
}

private func testSocketAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_len = UInt8(testSocketAddressLength(path: path))
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

private func testSocketAddressLength(path: String) -> socklen_t {
    socklen_t(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
}
