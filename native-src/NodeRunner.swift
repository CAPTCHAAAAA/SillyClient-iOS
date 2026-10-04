import Foundation
import Darwin

private typealias NodeStartFunc = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

struct IOSRuntimeLogFrame {
    static let prefix = "[SILLYCLIENT_LOG_V1]"
    static let maximumFrameBytes = 24 * 1024
    static let maximumLineBytes = 16 * 1024
    let instanceId: String
    let operationId: String
    let stream: String
    let line: String

    static func validIdentity(_ value: String) -> Bool {
        let bytes = value.utf8
        return (1...128).contains(bytes.count) && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func decode(_ raw: Data) -> IOSRuntimeLogFrame? {
        guard raw.count <= maximumFrameBytes, raw.starts(with: prefix.utf8),
              let value = try? JSONSerialization.jsonObject(with: Data(raw.dropFirst(prefix.utf8.count))) as? [String: Any],
              Set(value.keys) == Set(["instanceId", "operationId", "stream", "lineBase64"]),
              let instance = value["instanceId"] as? String, validIdentity(instance),
              let operation = value["operationId"] as? String, validIdentity(operation),
              let stream = value["stream"] as? String, ["stdout", "stderr"].contains(stream),
              let encoded = value["lineBase64"] as? String,
              encoded.utf8.count <= ((maximumLineBytes + 2) / 3) * 4,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= maximumLineBytes,
              !bytes.contains(10), let line = String(data: bytes, encoding: .utf8) else { return nil }
        return IOSRuntimeLogFrame(instanceId: instance, operationId: operation, stream: stream, line: line)
    }
}

public final class NodeRunner {
    public static let shared = NodeRunner()
    private let queue = DispatchQueue(label: "com.sillyclient.runtime-state")
    private let outputQueue = DispatchQueue(label: "com.sillyclient.runtime-output", qos: .utility)
    private let logLock = NSLock()
    private let queueKey = DispatchSpecificKey<Bool>()
    private let fm = FileManager.default
    private var state = "idle"
    private var instanceId: String?
    private var operationId: String?
    private var currentPort = 0
    private var currentURL = ""
    private var startedAt: Date?
    private var maintenance = Set<String>()
    private var hostInvoked = false
    private var hostExited = false
    private var sequence: UInt64 = 0
    private var pending: [String: (([String: Any]) -> Void, DispatchWorkItem)] = [:]
    private var mailboxSources: [DispatchSourceFileSystemObject] = []
    private var pipeSource: DispatchSourceRead?
    private var lineBytes = Data()
    private var discardingOutputLine = false
    private var logs: [String: [String]] = [:]
    private var logBytes: [String: Int] = [:]
    private var pendingLogCount = 0
    private var pendingLogBytes = 0
    private var logEvent: ((String, String, String) -> Void)?
    private var stateEvent: (([String: Any]) -> Void)?
    private let control: URL

    private init() {
        control = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .resolvingSymlinksInPath().appendingPathComponent("SillyClient/runtime", isDirectory: true)
        queue.setSpecific(key: queueKey, value: true)
    }

    private func readState<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) == true ? body() : queue.sync(execute: body)
    }
    public var isRunning: Bool { readState { state == "ready" } }
    public var status: [String: Any] { readState { statusLocked() } }
    public func setEventHandlers(log: @escaping (String, String, String) -> Void,
                                 status: @escaping ([String: Any]) -> Void) {
        queue.async { self.logEvent = log; self.stateEvent = status }
    }

    private func statusLocked() -> [String: Any] {
        var value: [String: Any] = ["serverReady": state == "ready", "state": state,
            "mode": "local", "url": currentURL, "port": currentPort,
            "uptimeSeconds": startedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0]
        if let id = instanceId { value["instanceId"] = id }
        if let id = operationId { value["operationId"] = id }
        return value
    }

    func reserve(instance: String, operation: String) throws {
        try queue.sync {
            guard !hostExited, instanceId == nil, maintenance.isEmpty else {
                throw IOSFileError.invalid("Stop the current operation before starting an instance")
            }
            instanceId = instance
            operationId = operation
            state = "provisioning"
            currentURL = ""
            currentPort = 0
            startedAt = nil
            stateEvent?(statusLocked())
        }
    }

    func checkCurrent(instance: String, operation: String) throws {
        try queue.sync {
            guard instanceId == instance, operationId == operation, state == "provisioning" || state == "starting" else {
                throw IOSFileError.invalid("Operation cancelled or superseded")
            }
        }
    }

    func failProvision(instance: String, operation: String, error: Error) {
        queue.async {
            guard self.instanceId == instance, self.operationId == operation, self.state == "provisioning" else { return }
            self.appendLog("Provisioning failed: \(error.localizedDescription)", instance: instance, operation: operation)
            self.instanceId = nil
            self.operationId = nil
            self.state = "failed"
            self.stateEvent?(self.statusLocked())
        }
    }

    func beginMaintenance(instance: String) throws {
        try queue.sync {
            guard instanceId == nil, maintenance.isEmpty else {
                throw IOSFileError.invalid("Instance maintenance requires a stopped runtime")
            }
            maintenance.insert(instance)
        }
    }

    func endMaintenance(instance: String) { queue.sync { maintenance.remove(instance) } }

    func stoppedMutation<T>(instance: String, _ body: () throws -> T) throws -> T {
        try queue.sync {
            guard instanceId == nil, maintenance.contains(instance) else {
                throw IOSFileError.invalid("The instance is no longer stopped")
            }
            return try body()
        }
    }

    func provisionMutation<T>(instance: String, operation: String, _ body: () throws -> T) throws -> T {
        try queue.sync {
            guard instanceId == instance, operationId == operation, state == "provisioning" else {
                throw IOSFileError.invalid("Operation cancelled or superseded")
            }
            return try body()
        }
    }

    func startPrepared(instance: String, operation: String, server: URL, data: URL,
                       config: URL, port: Int, ipv4: Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async {
            do {
                guard self.instanceId == instance, self.operationId == operation, self.state == "provisioning" else {
                    throw IOSFileError.invalid("Operation cancelled or superseded")
                }
                try self.ensureHost()
                self.currentPort = port
                self.currentURL = ipv4 ? "http://127.0.0.1:\(port)/" : "http://[::1]:\(port)/"
                self.state = "starting"
                self.sendLocked(["action": "start", "instanceId": instance, "operationId": operation,
                    "serverDirectory": server.path, "dataDirectory": data.path, "configPath": config.path,
                    "port": port, "ipv4": ipv4], timeout: 100) { response in
                    guard self.instanceId == instance, self.operationId == operation else {
                        completion(.failure(IOSFileError.invalid(response["error"] as? String
                            ?? "The runtime response belongs to an obsolete operation")))
                        return
                    }
                    guard response["success"] as? Bool == true else {
                        if response["transportUncertain"] as? Bool == true, self.state != "stopping" {
                            self.state = "uncertain"
                            self.stateEvent?(self.statusLocked())
                        } else if self.instanceId == instance, self.operationId == operation, self.state != "stopping" {
                            self.instanceId = nil
                            self.operationId = nil
                            self.state = "failed"
                            self.currentURL = ""
                            self.startedAt = nil
                            self.stateEvent?(self.statusLocked())
                        }
                        completion(.failure(IOSFileError.invalid(response["error"] as? String ?? "Runtime startup failed")))
                        return
                    }
                    guard self.instanceId == instance, self.operationId == operation, self.state != "stopping" else {
                        completion(.failure(IOSFileError.invalid("The ready response belongs to an obsolete operation")))
                        return
                    }
                    self.state = "ready"
                    self.startedAt = Date()
                    self.stateEvent?(self.statusLocked())
                    completion(.success(self.statusLocked()))
                }
            } catch {
                if self.instanceId == instance, self.operationId == operation {
                    self.instanceId = nil
                    self.operationId = nil
                    self.state = "failed"
                }
                completion(.failure(error))
            }
        }
    }

    public func stop(instance: String? = nil, operation: String? = nil,
                     completion: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async {
            guard (instance == nil || instance == self.instanceId), (operation == nil || operation == self.operationId) else {
                completion?(.failure(IOSFileError.invalid("The requested session is no longer current")))
                return
            }
            guard let id = self.instanceId, let op = self.operationId else { completion?(.success(())); return }
            if self.state == "provisioning" {
                self.instanceId = nil
                self.operationId = nil
                self.state = "stopped"
                self.stateEvent?(self.statusLocked())
                completion?(.success(()))
                return
            }
            guard self.state != "stopping" else {
                completion?(.failure(IOSFileError.invalid("The current session is already stopping")))
                return
            }
            self.state = "stopping"
            self.sendLocked(["action": "stop", "instanceId": id, "operationId": op], timeout: 15) { response in
                guard response["success"] as? Bool == true else {
                    self.state = "failed"
                    self.stateEvent?(self.statusLocked())
                    completion?(.failure(IOSFileError.invalid(response["error"] as? String ?? "Runtime stop failed")))
                    return
                }
                self.instanceId = nil
                self.operationId = nil
                self.state = "stopped"
                self.currentURL = ""
                self.currentPort = 0
                self.startedAt = nil
                self.stateEvent?(self.statusLocked())
                completion?(.success(()))
            }
        }
    }

    public func triggerGarbageCollection() {
        queue.async {
            guard self.hostInvoked, !self.hostExited else { return }
            self.sendLocked(["action": "gc"], timeout: 5) { response in
                self.appendLog(response["success"] as? Bool == true
                    ? "Host garbage collection completed; worker collection was requested"
                    : "Runtime garbage collection is unavailable")
            }
        }
    }

    private func ensureHost() throws {
        guard !hostExited else { throw IOSFileError.invalid("The embedded host exited; restart the application") }
        if hostInvoked { return }
        guard let script = Bundle.main.path(forResource: "ios-supervisor", ofType: "mjs")
            ?? Bundle(for: NodeRunner.self).path(forResource: "ios-supervisor", ofType: "mjs") else {
            throw IOSFileError.invalid("The embedded runtime supervisor is missing")
        }
        try fm.createDirectory(at: control, withIntermediateDirectories: true)
        let files = IOSManagedFiles(root: control)
        for name in ["requests", "responses"] {
            let directory = control.appendingPathComponent(name)
            try files.createDirectory(directory)
            for file in try files.children(directory, limit: 256) { try fm.removeItem(at: files.checked(file)) }
        }
        for name in ["status.json", "status.json.tmp"] {
            let file = control.appendingPathComponent(name)
            if files.exists(file) { try fm.removeItem(at: files.checked(file)) }
        }
        try watch(control)
        try watch(control.appendingPathComponent("responses"))
        try redirectOutput()
        signal(SIGPIPE, SIG_IGN)
        setenv("SILLYCLIENT_CONTROL_DIR", control.path, 1)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
        setenv("SILLYCLIENT_INSTANCES_ROOT", documents.path, 1)
        setenv("ST_DISABLE_SHARP", "true", 1)
        setenv("NODE_ENV", "production", 1)
        hostInvoked = true
        let thread = Thread {
            let code = self.invokeNodeStart(arguments: ["node", "--expose-gc", script])
            self.queue.async {
                self.hostExited = true
                self.state = "failed"
                self.appendLog("Embedded host exited (\(code)); application restart is required")
                for (_, value) in self.pending {
                    value.1.cancel()
                    value.0(["success": false, "error": "Embedded runtime host exited"])
                }
                self.pending.removeAll()
                self.stateEvent?(self.statusLocked())
            }
        }
        thread.stackSize = 4 * 1024 * 1024
        thread.name = "com.sillyclient.nodejs-host"
        thread.start()
    }

    private func watch(_ directory: URL) throws {
        let fd = open(directory.path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw IOSFileError.invalid("Runtime mailbox cannot be observed") }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.readMailbox() }
        source.setCancelHandler { close(fd) }
        mailboxSources.append(source)
        source.resume()
    }

    private func sendLocked(_ value: [String: Any], timeout: TimeInterval, completion: @escaping ([String: Any]) -> Void) {
        sequence += 1
        let id = String(format: "%016llu", sequence) + "-" + UUID().uuidString
        var request = value
        request["requestId"] = id
        let expiry = DispatchWorkItem {
            if let value = self.pending.removeValue(forKey: id) {
                value.0(["success": false, "transportUncertain": true,
                    "error": "Runtime command timed out; stop confirmation is still required"])
            }
        }
        do {
            guard pending.count < 32 else { throw IOSFileError.invalid("Runtime command queue is full") }
            pending[id] = (completion, expiry)
            try IOSManagedFiles(root: control).writeJSON(request,
                to: control.appendingPathComponent("requests/\(id).json"), replace: false)
            queue.asyncAfter(deadline: .now() + timeout, execute: expiry)
        } catch {
            pending.removeValue(forKey: id)
            completion(["success": false, "error": error.localizedDescription])
        }
    }

    private func readMailbox() {
        let files = IOSManagedFiles(root: control)
        if let report = try? files.json(control.appendingPathComponent("status.json")),
           report["instanceId"] as? String == instanceId, report["operationId"] as? String == operationId,
           let next = report["state"] as? String, next == "failed", state != "stopping" {
            state = "failed"
            currentURL = ""
            instanceId = nil
            operationId = nil
            startedAt = nil
            stateEvent?(statusLocked())
        }
        guard let responses = try? files.children(control.appendingPathComponent("responses"), limit: 256) else { return }
        for file in responses where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard let response = try? files.json(file) else { continue }
            try? fm.removeItem(at: files.checked(file))
            if let callback = pending.removeValue(forKey: id) {
                callback.1.cancel()
                callback.0(response)
            }
        }
    }

    private func invokeNodeStart(arguments: [String]) -> Int32 {
        var symbol = dlsym(dlopen(nil, RTLD_NOW), "node_start")
        if symbol == nil,
           let handle = dlopen((Bundle.main.privateFrameworksPath ?? "") + "/NodeMobile.framework/NodeMobile", RTLD_NOW) {
            symbol = dlsym(handle, "node_start")
        }
        guard let symbol = symbol else { return -1 }
        let start = unsafeBitCast(symbol, to: NodeStartFunc.self)
        var pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        pointers.append(nil)
        let code = pointers.withUnsafeMutableBufferPointer { start(Int32(arguments.count), $0.baseAddress) }
        pointers.forEach { if let pointer = $0 { free(pointer) } }
        return code
    }

    private func redirectOutput() throws {
        guard pipeSource == nil else { return }
        var descriptors = [Int32](repeating: 0, count: 2)
        guard pipe(&descriptors) == 0 else { throw IOSFileError.invalid("Runtime log pipe is unavailable") }
        guard dup2(descriptors[1], STDOUT_FILENO) >= 0 else {
            close(descriptors[0]); close(descriptors[1])
            throw IOSFileError.invalid("Runtime stdout could not be redirected")
        }
        close(descriptors[1])
        let readFd = descriptors[0]
        let source = DispatchSource.makeReadSource(fileDescriptor: readFd, queue: outputQueue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 32768)
            let count = Darwin.read(readFd, &buffer, buffer.count)
            guard count > 0 else { return }
            var bytes = Data(buffer.prefix(count))
            if self.discardingOutputLine {
                guard let end = bytes.firstIndex(of: 10) else { return }
                bytes.removeSubrange(...end)
                self.discardingOutputLine = false
            }
            self.lineBytes.append(bytes)
            while let end = self.lineBytes.firstIndex(of: 10) {
                let line = Data(self.lineBytes.prefix(upTo: end))
                self.lineBytes.removeSubrange(...end)
                self.consumeOutputLine(line)
            }
            if self.lineBytes.count > 65536 {
                self.lineBytes.removeAll(keepingCapacity: true)
                self.discardingOutputLine = true
                self.appendLog("[Oversized runtime log line discarded]", publishEvent: false)
            }
        }
        source.setCancelHandler { close(readFd) }
        pipeSource = source
        source.resume()
    }

    private func consumeOutputLine(_ raw: Data) {
        Self.routeCapturedOutput(raw) { line, instance, operation, publishEvent in
            self.appendLog(line, instance: instance, operation: operation, publishEvent: publishEvent)
        }
    }

    static func routeCapturedOutput(_ raw: Data, append: (String, String, String, Bool) -> Void) {
        guard raw.count <= 65536 else {
            append("[Oversized runtime log line discarded]", "runtime", "", false)
            return
        }
        if raw.starts(with: IOSRuntimeLogFrame.prefix.utf8) {
            guard let frame = IOSRuntimeLogFrame.decode(raw) else {
                append("[Malformed runtime log frame discarded]", "runtime", "", false)
                return
            }
            append(frame.line, frame.instanceId, frame.operationId, true)
        } else {
            // Capacitor itself writes listener delivery to process stdout.
            append(String(decoding: raw, as: UTF8.self), "runtime", "", false)
        }
    }

    public func appendLog(_ raw: String, instance id: String = "runtime", operation op: String = "") {
        appendLog(raw, instance: id, operation: op, publishEvent: true)
    }

    private func appendLog(_ raw: String, instance id: String = "runtime", operation op: String = "",
                           publishEvent: Bool) {
        guard IOSRuntimeLogFrame.validIdentity(id), op.isEmpty || IOSRuntimeLogFrame.validIdentity(op) else { return }
        var bytes = Data(raw.utf8.prefix(IOSRuntimeLogFrame.maximumLineBytes))
        while !bytes.isEmpty, String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        let line = (String(data: bytes, encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
        guard !line.isEmpty else { return }
        let size = line.utf8.count
        logLock.lock()
        guard pendingLogCount < 256, pendingLogBytes + size <= 512 * 1024 else {
            logLock.unlock()
            return
        }
        pendingLogCount += 1
        pendingLogBytes += size
        logLock.unlock()
        queue.async {
            self.logLock.lock()
            var buffer = self.logs[id] ?? []
            var bytes = self.logBytes[id] ?? 0
            buffer.append(line)
            bytes += line.utf8.count
            while buffer.count > 1000 || bytes > 512 * 1024 {
                bytes -= buffer.removeFirst().utf8.count
            }
            self.logs[id] = buffer
            self.logBytes[id] = bytes
            if self.logs.count > 32, let old = self.logs.keys.sorted().first(where: { $0 != id }) {
                self.logs.removeValue(forKey: old)
                self.logBytes.removeValue(forKey: old)
            }
            self.logLock.unlock()
            if publishEvent { self.logEvent?(id, op, line) }
            self.outputQueue.async {
                defer {
                    self.logLock.lock()
                    self.pendingLogCount -= 1
                    self.pendingLogBytes -= size
                    self.logLock.unlock()
                }
                guard self.fm.fileExists(atPath: self.control.path), let data = (line + "\n").data(using: .utf8) else { return }
                let target = self.control.appendingPathComponent("\(id).log")
                do {
                    let files = IOSManagedFiles(root: self.control)
                    if files.exists(target), try files.guardValue(target).size + Int64(data.count) > 1024 * 1024 {
                        let previous = self.control.appendingPathComponent("\(id).log.1")
                        if files.exists(previous) { try self.fm.removeItem(at: files.checked(previous)) }
                        try files.move(target, to: previous)
                    }
                    if !files.exists(target) { try files.write(Data(), to: target, replace: false) }
                    _ = try files.checked(target)
                    let fd = open(target.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
                    guard fd >= 0 else { return }
                    defer { close(fd) }
                    _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                } catch {}
            }
        }
    }

    public func getLogs(limit: Int = 200, instance: String? = nil) -> [String] {
        let id = instance ?? (status["instanceId"] as? String ?? "runtime")
        logLock.lock()
        defer { logLock.unlock() }
        return Array((logs[id] ?? []).suffix(max(0, min(500, limit))))
    }
}
