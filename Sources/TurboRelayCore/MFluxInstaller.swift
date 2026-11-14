import Foundation

/// Installs the mflux worker's Python environment on demand (plan decision 2).
///
/// The app ships `worker.py` and `requirements.txt`; the venv lives in the relay home and is
/// created on the first mflux job, never at launch, so a relay that never runs Krea 2 or
/// Qwen-Image 2.1 never downloads Python or mflux. `uv` does both steps: it fetches Python 3.13
/// if this Mac lacks it, then mflux 0.24.0 with its pinned MLX and their dependencies.
public final class MFluxInstaller: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case missing
        case installing
        case installed
        case failed(String)
    }

    private let lock = NSLock()
    private var currentState: State
    private var waiters: [(Bool, String?) -> Void] = []
    private var process: Process?
    private let home: URL
    private let requirementsPath: String
    private let uvPath: String?

    /// The installer's own log lines (one line when it starts, the tail on failure).
    public var onLog: ((String) -> Void)?
    /// The state changed: the menu and /models can refresh.
    public var onChange: (() -> Void)?

    public init(home: URL, requirementsPath: String) {
        self.home = home
        self.requirementsPath = requirementsPath
        self.uvPath = Self.findUV()
        self.currentState = FileManager.default.isExecutableFile(atPath: Self.pythonPath(home).path)
            ? .installed : .missing
    }

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    /// `<relay home>/mflux-venv/bin/python`: the interpreter the worker runs under.
    public var pythonPath: String { Self.pythonPath(home).path }

    private static func pythonPath(_ home: URL) -> URL {
        home.appendingPathComponent("mflux-venv/bin/python")
    }

    public func statusJSON() -> [String: Any] {
        switch state {
        case .missing: return ["state": "missing"]
        case .installing: return ["state": "installing"]
        case .installed: return ["state": "installed"]
        case .failed(let message): return ["state": "failed", "message": message]
        }
    }

    /// Ensures the venv exists, coalescing concurrent jobs onto one install. The completion
    /// runs on the installer's queue; `true` means the venv's Python is ready.
    public func ensureInstalled(_ completion: @escaping (Bool, String?) -> Void) {
        lock.lock()
        switch currentState {
        case .installed:
            lock.unlock()
            completion(true, nil)
            return
        case .installing:
            waiters.append(completion)
            lock.unlock()
            return
        case .missing, .failed:
            currentState = .installing
            lock.unlock()
        }
        onChange?()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.install(first: completion)
        }
    }

    /// Stops the install (the app is quitting). A later job can try again.
    public func stopInstall() {
        lock.lock()
        let process = process
        lock.unlock()
        process?.terminate()
    }

    // MARK: - Install

    private func install(first: @escaping (Bool, String?) -> Void) {
        guard let uvPath else {
            finish(false, message: "uv is not installed on the render Mac. Install it with `brew install uv` (or from https://astral.sh/uv), then run the job again.", first: first)
            return
        }
        onLog?("installing the mflux engine (Python 3.13, mflux 0.24.0): the first Krea 2 or Qwen-Image 2.1 job does this once")

        let venv = home.appendingPathComponent("mflux-venv", isDirectory: true).path
        let venvRun = run(uvPath, ["venv", "--clear", "--python", "3.13", venv])
        guard venvRun.code == 0 else {
            finish(false, message: "Could not create the mflux venv with uv: \(venvRun.tail)", first: first)
            return
        }
        let installRun = run(uvPath, ["pip", "install", "--python", pythonPath, "-r", requirementsPath])
        guard installRun.code == 0, FileManager.default.isExecutableFile(atPath: pythonPath) else {
            finish(false, message: "Could not install mflux: \(installRun.tail)", first: first)
            return
        }
        onLog?("mflux installed: \(pythonPath)")
        finish(true, message: nil, first: first)
    }

    private func finish(_ success: Bool, message: String?, first: @escaping (Bool, String?) -> Void) {
        lock.lock()
        currentState = success ? .installed : .failed(message ?? "mflux installation failed")
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        onChange?()
        first(success, message)
        for waiter in pending { waiter(success, message) }
    }

    private func run(_ executable: String, _ arguments: [String]) -> (code: Int32, tail: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        lock.lock()
        self.process = process
        lock.unlock()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lock.lock()
        self.process = nil
        lock.unlock()
        let output = String(decoding: data, as: UTF8.self)
        // The last lines carry uv's error; progress bars would only flood the engine log.
        let tail = output.split(separator: "\n").suffix(6).joined(separator: " ")
        return (process.terminationStatus, String(tail.suffix(600)))
    }

    /// The uv the app runs: Homebrew's, uv's own installer's, or one on PATH (a GUI app's PATH
    /// is short, so the usual locations come first).
    private static func findUV() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            home.appendingPathComponent(".local/bin/uv").path,
            home.appendingPathComponent(".cargo/bin/uv").path,
        ]
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/uv"
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
