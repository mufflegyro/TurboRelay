import Foundation

/// Routes wire commands to the native `turbo-engine` or the mflux worker, one model at a time.
///
/// Each engine is its own `EngineSupervisor` (same pipe protocol, different executable). A
/// command for the engine that is not active waits until the active engine's jobs finish;
/// then the old process is stopped — freeing its model — and the target one starts. The
/// native engine starts with the relay; the mflux worker starts on its first command.
public final class EngineRouter: @unchecked Sendable {
    private struct Pending {
        var engine: ModelEngine
        var line: String
        /// A generate's id; nil for load/unload, which start no job.
        var jobID: String?
    }

    private let lock = NSLock()
    private var supervisors: [ModelEngine: EngineSupervisor] = [:]
    private var active: ModelEngine?
    private var pending: [Pending] = []
    private var running: [ModelEngine: Int] = [:]
    private var started: Set<ModelEngine> = []

    /// Events from the active engine only; a stopped engine's trailing lines are dropped.
    public var onEvent: ((ModelEngine, String) -> Void)?
    /// Log lines from either engine, always forwarded (the log is how a missing mflux shows).
    public var onLog: ((ModelEngine, String) -> Void)?
    /// A process exited; `intentional` is true for a switch, false for a crash.
    public var onExit: ((ModelEngine, Bool) -> Void)?
    /// The active engine changed; the menu refreshes even before the new engine's ready.
    public var onActiveChange: (() -> Void)?

    /// `factory` returns a configured supervisor, or nil for an engine that is not installed.
    public init(factory: (ModelEngine) -> EngineSupervisor?) {
        for engine in ModelEngine.allCases {
            guard let supervisor = factory(engine) else { continue }
            supervisors[engine] = supervisor
            supervisor.onEvent = { [weak self] line in self?.deliverEvent(engine, line) }
            supervisor.onLog = { [weak self] line in self?.onLog?(engine, line) }
            supervisor.onExit = { [weak self] intentional in self?.handleExit(engine, intentional: intentional) }
        }
    }

    /// Whether this engine is installed at all (the mflux venv may be missing).
    public func isAvailable(_ engine: ModelEngine) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return supervisors[engine] != nil
    }

    /// Adds an engine after launch — the mflux worker, once its lazy install finishes. The old
    /// supervisor, if any, is stopped; the callbacks are wired the same way as at init.
    public func register(_ supervisor: EngineSupervisor, for engine: ModelEngine) {
        lock.lock()
        let previous = supervisors[engine]
        supervisors[engine] = supervisor
        lock.unlock()
        previous?.stop()
        supervisor.onEvent = { [weak self] line in self?.deliverEvent(engine, line) }
        supervisor.onLog = { [weak self] line in self?.onLog?(engine, line) }
        supervisor.onExit = { [weak self] intentional in self?.handleExit(engine, intentional: intentional) }
    }

    public func activeEngine() -> ModelEngine? {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    public func restartAttempts(_ engine: ModelEngine) -> Int {
        lock.lock()
        let supervisor = supervisors[engine]
        lock.unlock()
        return supervisor?.restartAttempts() ?? 0
    }

    /// Boots the native engine, the relay's default. The mflux worker waits for its first job.
    public func start() {
        var toStart: EngineSupervisor?
        var changed = false
        lock.lock()
        if active == nil, let turbo = supervisors[.turbo] {
            active = .turbo
            if !started.contains(.turbo) {
                started.insert(.turbo)
                toStart = turbo
            }
            changed = true
        }
        lock.unlock()
        toStart?.start()
        if changed { onActiveChange?() }
    }

    public func stop() {
        lock.lock()
        let all = Array(supervisors.values)
        pending.removeAll()
        active = nil
        started.removeAll()
        lock.unlock()
        all.forEach { $0.stop() }
    }

    /// Sends one engine command to `engine`; false when that engine is not installed.
    ///
    /// With the other engine's jobs still running, the command waits (fifo) for the switch;
    /// a generate reserves the job slot immediately, so only one engine ever holds a model.
    @discardableResult
    public func send(_ line: String, to engine: ModelEngine, startsJob: Bool = false,
                     jobID: String? = nil) -> Bool {
        var sendTo: EngineSupervisor?
        var stop: EngineSupervisor?
        var start: EngineSupervisor?
        var queued = false

        lock.lock()
        guard let supervisor = supervisors[engine] else {
            lock.unlock()
            return false
        }
        if active == engine {
            sendTo = supervisor
            // A crashed engine's supervisor restarts with backoff; a new job may start it
            // now instead of waiting (the delayed restart then finds it running).
            if !supervisor.isRunning { start = supervisor }
            if startsJob { running[engine, default: 0] += 1 }
        } else if let current = active, running[current, default: 0] > 0 {
            pending.append(Pending(engine: engine, line: line, jobID: jobID))
            queued = true
        } else {
            if let current = active, current != engine {
                stop = supervisors[current]
            }
            active = engine
            if !started.contains(engine) {
                started.insert(engine)
                start = supervisor
            }
            sendTo = supervisor
            if startsJob { running[engine, default: 0] += 1 }
        }
        lock.unlock()

        if queued { return true }
        stop?.stop()
        start?.start()
        sendTo?.send(line)
        if stop != nil || start != nil { onActiveChange?() }
        return true
    }

    /// Removes an engine that cannot run — the worker reported a fatal environment error (mflux
    /// missing from its venv, or the wrong version): stop it for good so the supervisor does not
    /// restart it, and free the active slot. The bridge fails its jobs.
    public func stopEngine(_ engine: ModelEngine) {
        lock.lock()
        let supervisor = supervisors.removeValue(forKey: engine)
        if active == engine { active = nil }
        lock.unlock()
        supervisor?.stop()
        onActiveChange?()
    }

    /// A command that is not tied to a family (unload): it goes to the engine holding the model.
    public func sendToActive(_ line: String) {
        lock.lock()
        let supervisor = active.flatMap { supervisors[$0] }
        lock.unlock()
        supervisor?.send(line)
    }

    /// Removes a still-queued generate. True means it never reached an engine; the bridge
    /// then reports it cancelled itself.
    public func cancel(jobID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let index = pending.firstIndex(where: { $0.jobID == jobID }) {
            pending.remove(at: index)
            return true
        }
        return false
    }

    /// A job reached a terminal event (done/failed/cancelled): one slot frees up, and a
    /// command waiting for the other engine can move.
    public func noteJobFinished(_ engine: ModelEngine) {
        lock.lock()
        running[engine] = max(0, running[engine, default: 1] - 1)
        lock.unlock()
        drain()
    }

    // MARK: - Switching

    /// Sends queued commands until one starts a job (which must finish first) or the queue
    /// empties. Only called when the active engine has no running jobs.
    private func drain() {
        while true {
            var next: Pending?
            lock.lock()
            if let current = active, running[current, default: 0] == 0, !pending.isEmpty {
                next = pending.removeFirst()
            }
            lock.unlock()
            guard let next else { return }
            let sent = send(next.line, to: next.engine, startsJob: next.jobID != nil, jobID: next.jobID)
            if !sent || next.jobID != nil { return }
        }
    }

    private func deliverEvent(_ engine: ModelEngine, _ line: String) {
        lock.lock()
        let isActive = active == engine
        lock.unlock()
        guard isActive else { return }
        onEvent?(engine, line)
    }

    private func handleExit(_ engine: ModelEngine, intentional: Bool) {
        lock.lock()
        // No job survives its engine; the bridge has failed them all by now.
        running[engine] = 0
        if intentional {
            started.remove(engine)
        }
        lock.unlock()
        onExit?(engine, intentional)
        // A crashed engine's supervisor restarts on its own; commands for the other engine
        // may now be free to run while it boots.
        drain()
    }
}
