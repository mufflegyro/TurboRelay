import Foundation

/// Owns one engine process (`turbo-engine serve`, the mflux worker, or the stub): spawns it,
/// feeds its stdin, splits stdout into event lines and stderr into log lines, and restarts it
/// with backoff if it dies on its own. The executable, its full argument list and its
/// environment are the caller's: the relay runs two of these (native and mflux).
public final class EngineSupervisor: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var shouldRestart = true
    private var expectedExit = false
    private var restartAttempt = 0
    private var startedAt = Date()

    /// "turbo-engine" or "mflux": names this engine in the relay's log and menu.
    public let name: String
    public let executablePath: String
    /// The complete spawn arguments (`["serve"]`, or `["worker.py", "serve"]`).
    public let arguments: [String]
    public let environment: [String: String]
    public var onEvent: ((String) -> Void)?
    public var onLog: ((String) -> Void)?
    /// The process exited. `intentional` is true when `stop()` asked for it (an engine
    /// switch); false means it crashed, which is also when the bridge fails its jobs.
    public var onExit: ((Bool) -> Void)?

    public init(name: String, executablePath: String, arguments: [String], environment: [String: String]) {
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    public func start() {
        lock.lock()
        expectedExit = false
        shouldRestart = true
        let running = process?.isRunning == true
        lock.unlock()
        guard !running else { return }
        spawn()
    }

    /// Stops for good (until `start()` again). The exit is reported as intentional, so the
    /// bridge does not treat an engine switch as a crash.
    public func stop() {
        lock.lock()
        shouldRestart = false
        expectedExit = true
        // A switch back starts a fresh lifetime, not the previous crash history.
        restartAttempt = 0
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
            onLog?("cannot send command: \(name) is not running")
            return
        }
        handle.write(Data((line + "\n").utf8))
    }

    private func spawn() {
        lock.lock()
        let running = process?.isRunning == true
        startedAt = Date()
        lock.unlock()
        guard !running else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
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
            let expected = self.expectedExit
            let restart = self.shouldRestart
            self.expectedExit = false
            self.stdinHandle = nil
            let lived = Date().timeIntervalSince(self.startedAt)
            self.restartAttempt = lived < 60 ? self.restartAttempt + 1 : 0
            let attempt = self.restartAttempt
            self.lock.unlock()

            // A crash fails the engine's in-flight jobs through the bridge; a switch has none
            // (the router only moves when the engine is idle).
            self.onExit?(expected)
            if expected {
                self.onLog?("[relay] \(self.name) stopped for an engine switch")
            } else {
                self.onLog?("[relay] \(self.name) exited; \(restart ? "restarting (attempt \(attempt))" : "staying stopped")")
            }
            guard restart else { return }
            let delay = min(10.0, 0.5 * pow(2.0, Double(attempt)))
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let restart = self.shouldRestart
                self.lock.unlock()
                guard restart else { return }
                self.spawn()
            }
        }

        do {
            try process.run()
        } catch {
            onLog?("[relay] could not start \(name) at \(executablePath): \(error.localizedDescription)")
            onExit?(false)
            return
        }
        lock.lock()
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        lock.unlock()

        pump(stdout.fileHandleForReading) { [weak self] line in self?.onEvent?(line) }
        pump(stderr.fileHandleForReading) { [weak self] line in self?.onLog?(line) }
        onLog?("[relay] engine started: \(name) — \(executablePath)")
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
