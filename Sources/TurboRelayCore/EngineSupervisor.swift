import Foundation

/// Owns the engine process (`turbo-engine serve`, or the stub): spawns it, feeds its stdin,
/// splits stdout into event lines and stderr into log lines, and restarts it with backoff
/// if it dies on its own. Mirrors the pattern of turbo-mlx's BackendController/LineProcess.
public final class EngineSupervisor: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var shouldRestart = true
    private var restartAttempt = 0
    private var startedAt = Date()

    public let enginePath: String
    public let environment: [String: String]
    /// The spawn arguments: "serve" plus any configured extras (config's engine_args).
    public let arguments: [String]
    public var onEvent: ((String) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onExit: (() -> Void)?

    public init(enginePath: String, environment: [String: String], arguments: [String] = []) {
        self.enginePath = enginePath
        self.environment = environment
        self.arguments = ["serve"] + arguments
    }

    public func start() {
        lock.lock()
        shouldRestart = true
        restartAttempt = 0
        lock.unlock()
        spawn()
    }

    public func stop() {
        lock.lock()
        shouldRestart = false
        let process = process
        lock.unlock()
        process?.terminate()
    }

    /// How many times the engine has been restarted in its current lifetime — nonzero means
    /// it keeps dying on its own (a crash-loop, e.g. missing resource bundles).
    public func restartAttempts() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return restartAttempt
    }

    public func send(_ line: String) {
        lock.lock()
        let handle = stdinHandle
        lock.unlock()
        guard let handle else {
            onLog?("cannot send command: the engine is not running")
            return
        }
        handle.write(Data((line + "\n").utf8))
    }

    private func spawn() {
        lock.lock()
        startedAt = Date()
        lock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: enginePath)
        process.arguments = arguments
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let restart = self.shouldRestart
            self.stdinHandle = nil
            let lived = Date().timeIntervalSince(self.startedAt)
            self.restartAttempt = lived < 60 ? self.restartAttempt + 1 : 0
            let attempt = self.restartAttempt
            self.lock.unlock()

            // The bridge fails in-flight jobs whether the engine restarts or not (spec
            // §Error model: crash → log + failed for the running job).
            self.onExit?()
            self.onLog?("[relay] engine exited; \(restart ? "restarting (attempt \(attempt))" : "staying stopped")")
            guard restart else { return }
            let delay = min(10.0, 0.5 * pow(2.0, Double(attempt)))
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.spawn()
            }
        }

        do {
            try process.run()
        } catch {
            onLog?("[relay] could not start the engine at \(enginePath): \(error.localizedDescription)")
            onExit?()
            return
        }
        lock.lock()
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        lock.unlock()

        pump(stdout.fileHandleForReading) { [weak self] line in self?.onEvent?(line) }
        pump(stderr.fileHandleForReading) { [weak self] line in self?.onLog?(line) }
        onLog?("[relay] engine started: \(enginePath)")
    }

    private func pump(_ handle: FileHandle, sink: @escaping (String) -> Void) {
        var buffer = Data()
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                sink(String(decoding: line, as: UTF8.self))
            }
        }
    }
}
