import Foundation

// StubEngine — a deterministic stand-in for `turbo-engine serve`, the engine-vocabulary
// layer of TurboRelay (TurboRelay/docs/remote-protocol.md §Layering). It speaks the same
// JSON-lines protocol as the real engine (commands on stdin, events on stdout, logs on
// stderr) without MLX or models: phases, progress, previews and results are simulated from
// the command's seed and steps, and every picture is a small deterministic PNG
// (MiniPNG.swift). TurboRelay spawns it where it would spawn the real engine, so the
// server and the client can be exercised end to end without downloading 5–38 GB models.
//
//   StubEngine serve [--staging DIR] [--step-delay-ms N] [--delay-ready-ms N]
//
// Behaviors mirrored from Engine/Sources/turbo-engine/Server.swift:
// - `ready` at startup, with memory in bytes and the families list
// - commands decoded strictly; an undecodable line is logged, never fatal
// - a reader thread feeds a queue; `cancel` is applied on arrival, not queued behind the
//   generation it targets
// - `output` names the file written; the caller (the bridge, or the conformance harness)
//   stages it — the engine layer is path-based by design, the wire layer is not
//
// The image-family event sequence is simulated: loading → model_loaded → encoding →
// denoising (with progress every step and a preview every second step) → decoding →
// saving → done. Family "invalid" simulates a broken checkpoint (load_failed → failed).

// MARK: - Wire types (mirror TurboEngineCore's Protocol.swift)

private struct Command: Decodable {
    let cmd: String
    let id: String?
    let model: ModelSpec?
    let params: GenerationParams?
}

private struct ModelSpec: Decodable {
    let family: String
    let path: String
    let name: String?
    let variant: String?
    let lowRam: Bool?
    let textEncoderPath: String?
    let quantize: Int?
}

private struct GenerationParams: Decodable {
    let prompt: String
    let negativePrompt: String?
    let seed: Int
    let width: Int
    let height: Int
    let steps: Int
    let guidance: Double
    let flattenAlpha: Bool?
    let output: String
    let upcomingPrompts: [String]?
    let frames: Int?
    let fps: Double?
    let autoDuration: Bool?
    let image: String?
    let lastImage: String?
    let images: [String]?
    let upscale: Double?
    let softness: Double?
    let precision: String?
    let preview: Bool?
    let loras: [LoRASpec]?
    let quality: Bool?
    let numGaussians: Int?
    let mode: String?
    let lyrics: String?
    let duration: Double?
}

private struct LoRASpec: Decodable {
    let path: String
    let scale: Double
}

private enum Wire {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func command(from line: String) throws -> Command {
        try decoder.decode(Command.self, from: Data(line.utf8))
    }
}

// MARK: - Emitter

private final class Emitter: @unchecked Sendable {
    private let lock = NSLock()
    private let out = FileHandle.standardOutput
    private let err = FileHandle.standardError

    /// `fields` values must be JSON-representable (String, Int, Double, Bool, arrays,
    /// dictionaries, NSNull) — as the engine's own Emitter requires.
    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        var object = fields
        object["event"] = event
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        lock.lock()
        out.write(data)
        out.write(Data("\n".utf8))
        lock.unlock()
    }

    func log(_ message: String) {
        lock.lock()
        err.write(Data((message + "\n").utf8))
        lock.unlock()
    }
}

// MARK: - Stub server

private final class StubServer: @unchecked Sendable {
    static let families = [
        "z-image-turbo", "flux2-klein", "flux3-klein", "moss-image", "qwen-image",
        "qwen-image-edit", "sensenova", "ming-image", "ltx-2", "ltx-2.5", "seedvr2",
        "minimax-music3", "moss-soundeffect",
    ]

    private let emitter = Emitter()
    private let queue = CommandQueue()
    private let staging: String
    private let stepDelaySeconds: Double
    private let delayReadySeconds: Double

    private let stateLock = NSLock()
    private var cancelledIDs: Set<String> = []

    /// Commands in arrival order; cancels are applied as soon as they are read.
    private final class CommandQueue: @unchecked Sendable {
        private var lines: [String] = []
        private let condition = NSCondition()
        weak var server: StubServer?

        func push(_ line: String) {
            if line.contains("\"crash\"") {
                // A mid-job crash, applied immediately like a real engine dying.
                FileHandle.standardError.write(Data("[stub] crashing on command\n".utf8))
                exit(2)
            }
            if line.contains("\"cancel\""),
               let command = try? Wire.command(from: line), command.cmd == "cancel", let id = command.id {
                server?.cancel(id: id)
                return
            }
            condition.lock()
            lines.append(line)
            condition.signal()
            condition.unlock()
        }

        func pop() -> String {
            condition.lock()
            while lines.isEmpty { condition.wait() }
            let line = lines.removeFirst()
            condition.unlock()
            return line
        }
    }

    init(staging: String, stepDelayMs: Int, delayReadyMs: Int = 0) {
        self.staging = staging
        self.stepDelaySeconds = Double(stepDelayMs) / 1000
        self.delayReadySeconds = Double(delayReadyMs) / 1000
        queue.server = self
    }

    func run() {
        let reader = Thread { [queue] in
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                queue.push(trimmed)
            }
            queue.push("{\"cmd\": \"shutdown\"}") // stdin closed: the caller is gone
        }
        reader.name = "stdin"
        reader.start()

        // --delay-ready-ms N: boot slowly, like the real engine does — for tests where a
        // client connects before the engine is ready (the bridge must broadcast ready).
        if delayReadySeconds > 0 { Thread.sleep(forTimeInterval: delayReadySeconds) }
        emitter.emit("ready", [
            "engine": "stub-engine 0.1",
            "mlx": "stub 0.1",
            "device": "Stub Silicon",
            "memory": Int(ProcessInfo.processInfo.physicalMemory),
            "families": StubServer.families,
        ])

        while true {
            let line = queue.pop()
            let command: Command
            do {
                command = try Wire.command(from: line)
            } catch {
                emitter.log("[stub] invalid command: \(line.prefix(200))")
                continue
            }
            switch command.cmd {
            case "shutdown":
                return
            case "crash":
                exit(2) // test-only: a mid-job engine crash, as if MLX had died
            case "generate":
                guard let id = command.id, let model = command.model, let params = command.params else {
                    emitter.log("[stub] generate needs id, model and params")
                    continue
                }
                generate(id: id, model: model, params: params)
            case "load":
                if let model = command.model { load(model, jobID: nil) }
            case "cancel":
                break // handled when it arrived
            case "unload":
                emitter.emit("unloaded")
            default:
                emitter.log("[stub] unknown command: \(command.cmd)")
            }
        }
    }

    func cancel(id: String) {
        stateLock.lock()
        cancelledIDs.insert(id)
        stateLock.unlock()
    }

    private func isCancelled(_ id: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelledIDs.contains(id)
    }

    // MARK: Command behaviors

    /// The output kind of a family, mirroring the engine's catalog: which phases run, which
    /// file format is written, and which extra fields `done` carries.
    private enum OutputKind {
        case image, video, song, sound, object

        var fileExtension: String {
            switch self {
            case .image: ".png"
            case .video: ".mp4"
            case .song, .sound: ".wav"
            case .object: ".glb"
            }
        }

        init(family: String) {
            switch family {
            case "ltx-2", "ltx-2.5": self = .video
            case "minimax-music3": self = .song
            case "moss-soundeffect": self = .sound
            case "idol": self = .object
            default: self = .image
            }
        }
    }

    private func load(_ model: ModelSpec, jobID: String?) {
        emitter.emit("phase", ["id": jobID.map { $0 as Any } ?? NSNull(), "phase": "loading"])
        if model.family == "invalid" {
            emitter.emit("load_failed", ["path": model.path, "message": "The stub rejects the family '\(model.family)'."])
            return
        }
        Thread.sleep(forTimeInterval: 0.03)
        emitter.emit("model_loaded", ["path": model.path, "seconds": 0.4])
    }

    private func generate(id: String, model: ModelSpec, params: GenerationParams) {
        let started = Date()
        let kind = OutputKind(family: model.family)

        emitter.emit("phase", ["id": id, "phase": "loading"])
        if model.family == "invalid" {
            emitter.emit("load_failed", ["path": model.path, "message": "The stub rejects the family '\(model.family)'."])
            emitter.emit("failed", ["id": id, "message": "The model could not be loaded."])
            return
        }
        Thread.sleep(forTimeInterval: 0.03)
        emitter.emit("model_loaded", ["path": model.path, "seconds": 0.4])

        if kind == .video {
            emitter.emit("phase", ["id": id, "phase": "encoding_video"])
        } else {
            emitter.emit("phase", ["id": id, "phase": "encoding"])
        }
        Thread.sleep(forTimeInterval: 0.02)

        if kind == .song {
            let frames = min(max(Int((params.duration ?? 10) * 25), 25), 500)
            emitter.emit("phase", ["id": id, "phase": "composing", "total": frames])
            for frame in 1...frames {
                if isCancelled(id) { emitter.emit("cancelled", ["id": id]); return }
                emitter.emit("progress", ["id": id, "step": frame, "total": frames])
            }
        }

        let steps = max(params.steps, 1)
        emitter.emit("phase", ["id": id, "phase": "denoising", "total": steps])
        for step in 1...steps {
            if isCancelled(id) {
                emitter.emit("cancelled", ["id": id])
                return
            }
            emitter.emit("progress", ["id": id, "step": step, "total": steps])
            if kind == .image, params.preview == true, step % 2 == 0 || step == steps {
                let url = URL(fileURLWithPath: staging).appendingPathComponent("preview-\(id)-\(step).png")
                MiniPNG.write(width: 64, height: 64, seed: params.seed, step: step, to: url)
                emitter.emit("preview", ["id": id, "step": step, "path": url.path])
            }
            if stepDelaySeconds > 0 { Thread.sleep(forTimeInterval: stepDelaySeconds) }
        }

        emitter.emit("phase", ["id": id, "phase": "decoding"])
        Thread.sleep(forTimeInterval: 0.02)
        emitter.emit("phase", ["id": id, "phase": "saving"])

        let outputURL = URL(fileURLWithPath: params.output)
        switch kind {
        case .image:
            MiniPNG.write(width: 64, height: 64, seed: params.seed, step: steps, to: outputURL)
        case .video:
            MiniFormats.writeMP4(seed: params.seed, frames: max(params.frames ?? 120, 1), to: outputURL)
        case .song, .sound:
            MiniFormats.writeWAV(seed: params.seed, seconds: params.duration ?? 5, to: outputURL)
        case .object:
            MiniFormats.writeGLB(seed: params.seed, gaussians: params.numGaussians ?? 262_144, to: outputURL)
        }

        let seconds = (Date().timeIntervalSince(started) * 100).rounded() / 100
        let timings: [String: Double] = [
            "load": 0.4,
            "encode": 0.2,
            "denoise": max(0.1, seconds - 0.9),
            "decode": 0.2,
            "save": 0.1,
        ]
        // The real engine logs its per-phase seconds on stderr at every done (Engine.swift).
        emitter.log("[stub] " + timings.map { "\($0.key) \(String(format: "%.1f", $0.value))s" }.sorted().joined(separator: " · "))
        var done: [String: Any] = [
            "id": id,
            "path": params.output,
            "seed": params.seed,
            "width": params.width,
            "height": params.height,
            "seconds": seconds,
            "peak_memory": 8_500_000_000,
            "timings": timings,
        ]
        switch kind {
        case .video:
            let frames = max(params.frames ?? 120, 1)
            done["frames"] = frames
            // The real engine writes a PNG still beside the clip ("poster", Engine.swift).
            let poster = URL(fileURLWithPath: staging).appendingPathComponent("poster-\(id).png")
            MiniPNG.write(width: 64, height: 64, seed: params.seed, step: steps, to: poster)
            done["poster"] = poster.path
        case .song:
            done["duration"] = params.duration ?? 10
            done["sample_rate"] = 44100
        case .sound:
            done["duration"] = params.duration ?? 10
            done["sample_rate"] = 48000
        case .object:
            done["gaussians"] = params.numGaussians ?? 262_144
        case .image:
            break
        }
        emitter.emit("done", done)
    }
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "serve" else {
    FileHandle.standardError.write(Data("usage: StubEngine serve [--staging DIR] [--step-delay-ms N] [--delay-ready-ms N]\n".utf8))
    exit(2)
}

var staging = NSTemporaryDirectory()
var stepDelayMs = 0
var delayReadyMs = 0
var index = 1
while index < arguments.count {
    switch arguments[index] {
    case "--staging":
        staging = arguments[index + 1]
        index += 2
    case "--step-delay-ms":
        stepDelayMs = Int(arguments[index + 1]) ?? 0
        index += 2
    case "--delay-ready-ms":
        delayReadyMs = Int(arguments[index + 1]) ?? 0
        index += 2
    default:
        index += 1
    }
}

try? FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
StubServer(staging: staging, stepDelayMs: stepDelayMs, delayReadyMs: delayReadyMs).run()
