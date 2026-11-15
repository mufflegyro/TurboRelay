import Foundation

// Client-transport end-to-end (loopback): compiles Turbo MLX's real client files —
// RemoteBackend, WorkerProtocol, BackendController, the catalog — into a small driver that
// connects to the real TurboRelay server + stub engine and runs the flow the app would run:
//
//   connect → ready with the server's memory (A4) → fetch the catalog (M3) →
//   generate with an uploaded reference image (A1) and stripped model paths (A2) →
//   previews as local files (A3) → the result written to the job's output path.
//
// Usage: client-e2e <RelayServer binary> <StubEngine binary>

var failures: [String] = []
let printLock = NSLock()

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    printLock.lock()
    print((ok ? "PASS " : "FAIL ") + name + (ok ? "" : " — \(detail)"))
    printLock.unlock()
    if !ok { failures.append(name) }
}

func waitFor(_ condition: @escaping () -> Bool, timeout: Double, interval: Double = 0.2) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: interval)
    }
    return condition()
}

func portOpen(_ port: UInt16) -> Bool {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    let result = connect(fd, sockaddr_cast(&address), socklen_t(MemoryLayout<sockaddr_in>.size))
    close(fd)
    return result == 0
}

func sockaddr_cast(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutablePointer<sockaddr> {
    pointer.assumingMemoryBound(to: sockaddr.self)
}

let token = String(repeating: "b7", count: 32)
let zID = "mflux-community/z-image-turbo-mflux-q4"
let clientToken = token
let arguments = CommandLine.arguments
let relayPath = arguments.count > 1 ? arguments[1] : "RelayServer"
let stubPath = arguments.count > 2 ? arguments[2] : "StubEngine"

/// A free TCP port, so concurrent or leaked servers cannot collide with this run.
func freePort() -> UInt16 {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(sock) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
            bind(sock, sockPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { return 7842 }
    var boundAddress = sockaddr_in()
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    getsockname(sock, sockaddr_cast(&boundAddress), &size)
    return UInt16(boundAddress.sin_port.bigEndian)
}

// --- client home: the reference image the request will upload lives here (TURBO_MLX_HOME)
let clientHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("client-e2e-\(UUID().uuidString)", isDirectory: true)
let references = clientHome.appendingPathComponent("References", isDirectory: true)
try? FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
try? Data("PNGDATA-reference".utf8).write(to: references.appendingPathComponent("ref-e2e.png"))
setenv("TURBO_MLX_HOME", clientHome.path, 1)
check("the reference image exists at HistoryStore.referenceURL",
      FileManager.default.fileExists(atPath: HistoryStore.referenceURL("ref-e2e.png").path),
      HistoryStore.referenceURL("ref-e2e.png").path)

// --- server home: config, a fake hub with the model the request names
let serverHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("server-e2e-\(UUID().uuidString)", isDirectory: true)
let hub = serverHome
    .appendingPathComponent("hfhub/models--mflux-community--z-image-turbo-mflux-q4/snapshots/cafef00d", isDirectory: true)
try? FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
try? Data("stub checkpoint".utf8).write(to: hub.appendingPathComponent("model.safetensors"))

// LTX-2.3, the model the Quality path was reported on: a complete-looking pack (the quality
// transformer included) with its Gemma 3 12B text encoder, so /models reports the model and
// its Quality files as downloaded without a network download.
let ltxID = "dgrauet/ltx-2.3-mlx-q4"
let ltxSnapshot = serverHome.appendingPathComponent(
    "hfhub/models--dgrauet--ltx-2.3-mlx-q4/snapshots/56a5866d638ecfe37c54d348e88938235185c2d4",
    isDirectory: true)
try? FileManager.default.createDirectory(at: ltxSnapshot, withIntermediateDirectories: true)
for name in ["embedded_config.json", "transformer-distilled-1.1.safetensors", "connector.safetensors",
             "vae_decoder.safetensors", "vae_encoder.safetensors", "audio_vae.safetensors",
             "vocoder.safetensors", "spatial_upscaler_x2_v1_1.safetensors",
             "transformer-dev.safetensors"] {
    try? Data("ltx fixture".utf8).write(to: ltxSnapshot.appendingPathComponent(name))
}
let gemmaSnapshot = serverHome.appendingPathComponent(
    "hfhub/models--mlx-community--gemma-3-12b-it-4bit/snapshots/86cc6a8dedbc456dd0e4af01a9d09f396f77e558",
    isDirectory: true)
try? FileManager.default.createDirectory(at: gemmaSnapshot, withIntermediateDirectories: true)
for name in ["config.json", "tokenizer.json",
             "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"] {
    try? Data("gemma fixture".utf8).write(to: gemmaSnapshot.appendingPathComponent(name))
}

let source = serverHome.appendingPathComponent("lora-source.safetensors")
// Larger than the stream's 1 MiB chunks, so the chunked response is exercised end to end.
let loraBytes = Data(repeating: 0x5A, count: 3 << 20)
try? loraBytes.write(to: source)
let loraID = String(repeating: "ab", count: 32)
let stagingLoras = serverHome.appendingPathComponent("staging/loras", isDirectory: true)
try? FileManager.default.createDirectory(at: stagingLoras, withIntermediateDirectories: true)
try? FileManager.default.createSymbolicLink(
    at: stagingLoras.appendingPathComponent("\(loraID)-Test LoRA.safetensors"),
    withDestinationURL: source)

let port: UInt16 = UInt16(freePort())
let serverConfig: [String: Any] = [
    "port": Int(port), "token": token, "engine_path": stubPath,
    "model_root": serverHome.appendingPathComponent("hfhub").path,
]
try? FileManager.default.createDirectory(at: serverHome, withIntermediateDirectories: true)
try? (try? JSONSerialization.data(withJSONObject: serverConfig, options: [.prettyPrinted]))?
    .write(to: serverHome.appendingPathComponent("config.json"))

let server = Process()
server.executableURL = URL(fileURLWithPath: relayPath)
server.environment = ["TURBORELAY_HOME": serverHome.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
let serverPipe = Pipe()
server.standardOutput = serverPipe
server.standardError = serverPipe

let eventsLock = NSLock()
var events: [WorkerEvent] = []

func collect(_ event: WorkerEvent) {
    eventsLock.lock()
    events.append(event)
    eventsLock.unlock()
}

func eventsMatching(_ predicate: (WorkerEvent) -> Bool) -> [WorkerEvent] {
    eventsLock.lock()
    defer { eventsLock.unlock() }
    return events.filter(predicate)
}

do { try server.run() } catch {
    print("could not start the server: \(error)")
    exit(1)
}
check("the server opened its port", waitFor({ portOpen(port) }, timeout: 10))

// --- the client under test
let client = RemoteBackend(serverURLString: "http://127.0.0.1:\(port)", token: token)
client.onEvent = { collect($0) }
client.ensureWorker()

check("ready arrives", waitFor({ client.status == .ready }, timeout: 10))
check("ready reports the server's memory in bytes (A4)", (client.info?.memory ?? 0) > 0, "\(client.info?.memory ?? -1)")
check("the engine is the stub on the render Mac", client.info?.device == "Stub Silicon", client.info?.device ?? "none")

// Catalog (M3)
var modelCount = 0
var catalogError = ""
let catalogDone = DispatchSemaphore(value: 0)
Task {
    do {
        modelCount = try await client.fetchModels().count
    } catch {
        catalogError = "\(error)"
    }
    catalogDone.signal()
}
catalogDone.wait()
check("fetchModels lists the catalog", modelCount >= 14, catalogError)
check("fetchModels seeds the picker's per-model states (M3)", !client.modelStates.isEmpty,
      "\(client.modelStates.count) states")
check("LTX-2.3 reports its Quality files as downloaded (seeded from /models quality_state)",
      client.qualityStates[ltxID]?.state == "downloaded",
      String(describing: client.qualityStates[ltxID]))

// The Quality request goes to its own route: a model without Quality files is refused with
// the server's reason, which the client stores for the Quality row to show.
guard let qualityless = ModelCatalog.builtIn.first(where: { $0.id == zID }) else {
    print("the catalog has no \(zID)")
    exit(1)
}
try? client.downloadQuality(qualityless)
check("a Quality request for a model without Quality files fails readably",
      waitFor({ client.qualityStates[zID]?.state == "failed"
                && (client.qualityStates[zID]?.message ?? "").contains("no Quality mode") }, timeout: 10),
      String(describing: client.qualityStates[zID]))

// The relay's LoRA library (GET /loras): a file a client used and the relay kept, backfilled
// from staging/loras at startup, streamed to disk for import. Removing the staging symlink and
// its source proves the library hardlink is independent of the upload.
try? FileManager.default.removeItem(at: stagingLoras.appendingPathComponent("\(loraID)-Test LoRA.safetensors"))
try? FileManager.default.removeItem(at: source)
var remoteLoRAs: [RemoteBackend.RemoteLoRA] = []
var remoteLoRAError = ""
let lorasDone = DispatchSemaphore(value: 0)
Task {
    do { remoteLoRAs = try await client.fetchLoRAs() } catch { remoteLoRAError = "\(error)" }
    lorasDone.signal()
}
lorasDone.wait()
let libraryLoRA = remoteLoRAs.first { $0.id == loraID }
check("fetchLoRAs lists the relay's library",
      libraryLoRA?.name == "Test LoRA.safetensors" && libraryLoRA?.bytes == Int64(loraBytes.count),
      "\(remoteLoRAs) \(remoteLoRAError)")
if let lora = libraryLoRA {
    var downloaded: URL?
    var downloadError = ""
    let downloadDone = DispatchSemaphore(value: 0)
    Task {
        do { downloaded = try await client.downloadLoRA(lora) } catch { downloadError = "\(error)" }
        downloadDone.signal()
    }
    downloadDone.wait()
    check("downloadLoRA streams the file to disk",
          downloaded.flatMap { try? Data(contentsOf: $0) } == loraBytes, downloadError)
    if let folder = downloaded?.deletingLastPathComponent() {
        try? FileManager.default.removeItem(at: folder)
    }
}

// Generate with a reference image: the request names it by its references-folder name, the
// transport uploads it and the command goes out with a handle (A1).
guard let model = ModelCatalog.builtIn.first(where: { $0.id == zID }) else {
    print("the catalog has no \(zID)")
    exit(1)
}
let jobID = UUID()
let output = clientHome.appendingPathComponent("result-e2e.png")
let request = GenerationRequest(
    prompt: "a puffin standing on a cliff", blocks: nil, negativePrompt: nil, seed: 42,
    size: PixelSize(width: 1024, height: 1024), steps: 4, guidance: 1,
    transparentBackground: false, lowMemory: false, frames: nil, fps: nil, autoDuration: nil,
    referenceImage: "ref-e2e.png", lastFrameImage: nil, upscale: nil, softness: nil,
    halfPrecision: nil, loras: nil, quality: nil, numGaussians: nil, objectMode: nil,
    lyrics: nil, duration: nil)

var generateError = ""
do {
    try client.send(.generate(
        jobID: jobID, model: model, modelPath: "/bogus/local/path-that-must-not-travel",
        textEncoderPath: "/bogus/companion", request: request, output: output,
        upcomingPrompts: [], preview: true))
} catch {
    generateError = "\(error)"
}
check("generate accepted", generateError.isEmpty, generateError)

var preview: WorkerEvent?
var done: WorkerEvent?
check("done arrives within 30 s", waitFor({
    eventsLock.lock()
    defer { eventsLock.unlock() }
    for event in events {
        if event.event == "preview", event.id == jobID.uuidString { preview = event }
        if event.event == "done", event.id == jobID.uuidString { done = event }
    }
    return done != nil
}, timeout: 30))

check("previews arrive as local files (A3)",
      preview != nil && FileManager.default.fileExists(atPath: preview?.path ?? "/nope"))
if let path = preview?.path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
    check("the preview file is a PNG", data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
}
check("done lands at the job's output path (A2, reversed)", done?.path == output.path, done?.path ?? "none")
check("the result file is a real PNG",
      (try? Data(contentsOf: output)).map { $0.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) } ?? false)
check("done keeps the seed and size", done?.seed == 42 && done?.width == 1024)

// The reference image was uploaded content-addressed, never sent as a path (A1).
let uploads = (try? FileManager.default.contentsOfDirectory(
    at: serverHome.appendingPathComponent("staging/uploads"), includingPropertiesForKeys: nil)) ?? []
check("the reference image sits in the server's content-addressed uploads", uploads.count == 1, "\(uploads.count)")

// The engine's stderr is relayed into the client's log (spec §Log relay).
check("log events were relayed into the log buffer", !client.log.text.isEmpty)

// --- Disconnect mid-job → reconnect → the result is delivered by job id (M4 acceptance).
// The transport must NOT treat a lost connection as a crash: the queue survives.
let job2 = UUID(uuidString: "e2e2222e-2222-4222-8222-222222222222")!
let output2 = clientHome.appendingPathComponent("result-e2e-2.png")
var generate2Error = ""
do {
    try client.send(.generate(
        jobID: job2, model: model, modelPath: "/bogus/local/path",
        textEncoderPath: nil, request: request, output: output2,
        upcomingPrompts: [], preview: false))
} catch {
    generate2Error = "\(error)"
}
check("second generate accepted", generate2Error.isEmpty, generate2Error)
// Drop the connection while the job renders; the stub takes a couple of seconds for it.
check("the job starts rendering on the render Mac", waitFor({
    eventsLock.lock()
    defer { eventsLock.unlock() }
    return events.contains { $0.event == "phase" && $0.id == job2.uuidString && $0.phase == "denoising" }
}, timeout: 10))
client.stopWorker()
Thread.sleep(forTimeInterval: 1.5)
// Reconnect: reconcileJobs must deliver the finished result by job id.
client.ensureWorker()
var done2: WorkerEvent?
check("the transport reconnects and delivers the finished result by job id", waitFor({
    eventsLock.lock()
    defer { eventsLock.unlock() }
    for event in events where event.event == "done" && event.id == job2.uuidString { done2 = event }
    return done2 != nil
}, timeout: 30))
check("the delivered result landed at the job's output path",
      done2 != nil && FileManager.default.fileExists(atPath: output2.path)
      && (try? Data(contentsOf: output2)).map { $0.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) } ?? false)

// --- The server's authoritative memory backstop (spec §Error model, amendment A4): a job
// whose estimated peak cannot fit the render Mac's memory is refused with a readable
// message, without ever reaching the engine.
let hugeJob = UUID()
let hugeRequest = GenerationRequest(
    prompt: "far too big for any Mac", blocks: nil, negativePrompt: nil, seed: 1,
    size: PixelSize(width: 8192, height: 8192), steps: 4, guidance: 1,
    transparentBackground: false, lowMemory: false, frames: nil, fps: nil, autoDuration: nil,
    referenceImage: nil, lastFrameImage: nil, upscale: nil, softness: nil,
    halfPrecision: nil, loras: nil, quality: nil, numGaussians: nil, objectMode: nil,
    lyrics: nil, duration: nil)
var memoryRefused = false
do {
    try client.send(.generate(
        jobID: hugeJob, model: model, modelPath: "/bogus/local/path",
        textEncoderPath: nil, request: hugeRequest, output: clientHome.appendingPathComponent("huge.png"),
        upcomingPrompts: [], preview: false))
    memoryRefused = waitFor({
        eventsLock.lock()
        defer { eventsLock.unlock() }
        return events.contains { $0.event == "failed" && $0.id == hugeJob.uuidString && ($0.message ?? "").lowercased().contains("memory") }
    }, timeout: 10)
} catch {
    memoryRefused = true // refused before it could even be sent counts too
}
check("a too-big generation is refused by the server's memory backstop", memoryRefused)

client.stopWorker()
server.terminate()

// --- Late-ready regression (the bug behind "Connecting..." forever): the real engine takes
// seconds to boot; a client that connects in the meantime must still receive the ready
// event when it arrives — the bridge broadcasts it, it does not only cache it for the
// connect greeting. The stub's --delay-ready-ms reproduces the real engine's slow boot.
let latePort: UInt16 = UInt16(freePort())
let lateHome = serverHome.appendingPathComponent("late", isDirectory: true)
try? FileManager.default.createDirectory(at: lateHome, withIntermediateDirectories: true)
try? (try? JSONSerialization.data(withJSONObject: [
    "port": Int(latePort), "token": token, "engine_path": stubPath,
    "model_root": serverHome.appendingPathComponent("hfhub").path,
    "engine_args": ["--delay-ready-ms", "2500"],
], options: [.prettyPrinted]))?.write(to: lateHome.appendingPathComponent("config.json"))

let lateServer = Process()
lateServer.executableURL = URL(fileURLWithPath: relayPath)
lateServer.environment = ["TURBORELAY_HOME": lateHome.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
lateServer.standardOutput = FileHandle.nullDevice
lateServer.standardError = FileHandle.nullDevice
do { try lateServer.run() } catch {
    print("could not start the late-ready server: \(error)")
    exit(1)
}
check("the late-ready server opened its port", waitFor({ portOpen(latePort) }, timeout: 10))

// The client connects while the engine is still booting (no ready cached yet).
let lateClient = RemoteBackend(serverURLString: "http://127.0.0.1:\(latePort)", token: token)
lateClient.ensureWorker()
check("late-ready arrives to a client connected before boot (ready broadcast)",
      waitFor({ lateClient.status == .ready }, timeout: 20))
check("late-ready reports the render Mac's memory", (lateClient.info?.memory ?? 0) > 0,
      "\(lateClient.info?.memory ?? -1)")

lateClient.stopWorker()
lateServer.terminate()

print("---- client log tail ----")
print(client.log.text.suffix(1200))
print("---- event kinds ----")
print(events.map { $0.event }.joined(separator: ","))
print("---- server home tree ----")
if let enumerator = FileManager.default.enumerator(at: serverHome, includingPropertiesForKeys: nil) {
    for case let url as URL in enumerator {
        print("  ", url.path.replacingOccurrences(of: serverHome.path, with: ""))
    }
}
let serverData = try? serverPipe.fileHandleForReading.readDataToEndOfFile()
print("---- server output ----")
print(String(decoding: serverData ?? Data(), as: UTF8.self).suffix(1200))

if failures.isEmpty {
    print("\nclient-transport e2e: all checks passed")
} else {
    print("\n\(failures.count) failing: \(failures.joined(separator: ", "))")
    exit(1)
}
