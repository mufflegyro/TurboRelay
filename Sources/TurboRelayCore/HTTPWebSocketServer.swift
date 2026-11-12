import Foundation
import Network
import CryptoKit

// A small HTTP/1.1 + WebSocket (RFC 6455) server on Network.framework: one TCP listener
// serving both the JSON endpoints (hello, jobs, uploads, files) and the /engine WebSocket
// channel. The WS codec is deliberately hand-rolled and minimal — text frames only,
// no fragmentation (clients our size don't fragment small JSON lines), ping→pong,
// close handled — so everything stays inspectable and the wire forms match
// TurboRelay/docs/remote-protocol.md exactly.

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

public struct HTTPResponse {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [:], body: data)
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        .json(["error": message], status: status)
    }

    public static func file(_ data: Data, mediaType: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": mediaType], body: data)
    }

    static func phrase(_ status: Int) -> String {
        switch status {
        case 101: "Switching Protocols"
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 501: "Not Implemented"
        default: "Status"
        }
    }
}

/// One upgraded WebSocket connection. Created by the server after the handshake; the
/// service sets `onText` before traffic flows.
public final class WSSession: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var open = true
    /// Frames sent before the 101 has been flushed; they go out the moment it has (a data
    /// frame coalesced into the 101's segment confuses some clients).
    private var pending: [Data] = []
    private var flushed = false
    private var pingTimer: DispatchSourceTimer?
    public var onText: ((String) -> Void)?
    public var onClose: (() -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    public func sendText(_ text: String) {
        let payload = Data(text.utf8)
        var frame = Data([0x81]) // FIN + text
        Self.appendLength(&frame, payload.count)
        frame.append(payload)
        lock.lock()
        if !flushed {
            pending.append(frame)
            lock.unlock()
            return
        }
        let isOpen = open
        lock.unlock()
        guard isOpen else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// Called once the 101 is on the wire: a greeting queued while the handshake flushed
    /// goes out now, after the 101 rather than coalesced into it.
    func markFlushed() {
        lock.lock()
        flushed = true
        let queued = pending
        pending.removeAll()
        lock.unlock()
        for frame in queued {
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
        startPinging()
    }

    /// Server-side keepalive (spec §Transport): detects half-open connections from sleeps and
    /// router timeouts; URLSession clients answer automatically.
    private func startPinging() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in
            self?.ping()
        }
        timer.resume()
        pingTimer = timer
    }

    private func ping() {
        lock.lock()
        defer { lock.unlock() }
        guard open else { return }
        connection.send(content: Data([0x89, 0x00]), completion: .contentProcessed { _ in })
    }

    func sendClose(code: UInt16 = 1000) {
        var body = Data()
        body.append(UInt8(code >> 8))
        body.append(UInt8(code & 0xFF))
        var frame = Data([0x88])
        Self.appendLength(&frame, body.count)
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func sendPong(_ payload: Data) {
        var frame = Data([0x8A]) // FIN + pong
        Self.appendLength(&frame, payload.count)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func handleClosed() {
        lock.lock()
        let wasOpen = open
        open = false
        pingTimer?.cancel()
        pingTimer = nil
        lock.unlock()
        if wasOpen {
            onClose?()
        }
    }

    public func close() {
        handleClosed()
        connection.cancel()
    }

    static func appendLength(_ frame: inout Data, _ length: Int) {
        if length < 126 {
            frame.append(UInt8(length))
        } else if length < 65536 {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> shift) & 0xFF))
            }
        }
    }
}

public final class HTTPWebSocketServer: @unchecked Sendable {
    public var onRequest: ((HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void)?
    public var onWebSocket: ((WSSession) -> Void)?
    public var onLog: ((String) -> Void)?
    /// Fired when a WS session registers or unregisters, so the menu's client count
    /// updates live instead of showing a stale count.
    public var onStateChange: (() -> Void)?

    private let port: UInt16
    private let token: String
    private var listener: NWListener?
    private let sessionsLock = NSLock()
    private var sessions: [WSSession] = []

    public init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    public var clientCount: Int {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        return sessions.count
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let endpoint = NWEndpoint.Port(rawValue: port) else {
            throw RelayError.badPort(port)
        }
        let listener = try NWListener(using: parameters, on: endpoint)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onStateChange?()
            case .failed(let error):
                self?.onLog?("[relay] listener failed: \(error) — is another copy of the server running on port \(self?.port ?? 0)?")
                self?.onStateChange?()
            case .waiting(let error):
                self?.onLog?("[relay] listener waiting: \(error)")
            default:
                break
            }
        }
        listener.start(queue: DispatchQueue(label: "turborelay.listener", qos: .utility))
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        sessionsLock.lock()
        let all = sessions
        sessions.removeAll()
        sessionsLock.unlock()
        all.forEach { $0.close() }
    }

    public func broadcast(_ text: String) {
        sessionsLock.lock()
        let all = sessions
        sessionsLock.unlock()
        all.forEach { $0.sendText(text) }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "turborelay.connection", qos: .utility))
        let handler = ConnectionHandler(connection: connection, server: self)
        pump(handler)
    }

    private func pump(_ handler: ConnectionHandler) {
        handler.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                handler.append(data)
            }
            if error != nil || (isComplete && data == nil) {
                handler.shutdown()
                return
            }
            self.pump(handler)
        }
    }

    func authorized(_ headers: [String: String]) -> Bool {
        headers["authorization"] == "Bearer \(token)"
    }

    func register(_ session: WSSession) {
        sessionsLock.lock()
        sessions.append(session)
        sessionsLock.unlock()
        onStateChange?()
    }

    func unregister(_ session: WSSession) {
        sessionsLock.lock()
        sessions.removeAll { $0 === session }
        sessionsLock.unlock()
        onStateChange?()
    }
}

enum RelayError: Error {
    case badPort(UInt16)
}

// MARK: - One TCP connection (HTTP then, after upgrade, WebSocket frames)

private final class ConnectionHandler {
    let connection: NWConnection
    private unowned let server: HTTPWebSocketServer
    private var buffer: [UInt8] = []
    private var upgraded = false
    private var session: WSSession?

    init(connection: NWConnection, server: HTTPWebSocketServer) {
        self.connection = connection
        self.server = server
    }

    func append(_ data: Data) {
        buffer.append(contentsOf: [UInt8](data))
        if upgraded {
            processFrames()
        } else {
            processHTTP()
        }
    }

    func shutdown() {
        if let session {
            session.handleClosed()
            server.unregister(session)
        }
        connection.cancel()
    }

    // MARK: HTTP

    private func processHTTP() {
        let headSeparator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let headEnd = buffer.firstRange(of: headSeparator) else { return }
        let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3 else {
            respond(.error(400, "malformed request line"))
            return
        }
        let method = String(parts[0])
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        guard buffer.count - bodyStart >= contentLength else { return } // wait for the body
        let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
        buffer.removeSubrange(buffer.startIndex..<(bodyStart + contentLength))

        let request = HTTPRequest(method: method, path: path, headers: headers, body: body)
        guard server.authorized(headers) else {
            respond(.error(401, "pairing token missing or wrong"))
            return
        }

        if method == "GET", path == "/engine",
           headers["upgrade"]?.lowercased() == "websocket",
           let key = headers["sec-websocket-key"] {
            upgrade(request, key: key)
            return
        }

        server.onRequest?(request) { [weak self] response in
            self?.respond(response)
        }
    }

    private func respond(_ response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(HTTPResponse.phrase(response.status))\r\n"
        var headers = response.headers
        if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    // MARK: WebSocket upgrade + frames

    private func upgrade(_ request: HTTPRequest, key: String) {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data(magic.utf8))).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        // Switch modes and wire the session *before* queueing the 101: the client cannot
        // send frames before it sees the 101, so no frame byte can be mistaken for HTTP.
        let session = WSSession(connection: connection)
        self.session = session
        server.register(session)
        upgraded = true
        server.onWebSocket?(session)
        // Flush the 101 on its own, and only then let the session greet (a cached ready
        // event): a data frame coalesced into the 101's segment confuses some clients.
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            session.markFlushed()
        })
    }

    private func processFrames() {
        while true {
            guard buffer.count >= 2 else { return }
            let b0 = buffer[0]
            let b1 = buffer[1]
            let opcode = b0 & 0x0F
            let fin = b0 & 0x80 != 0
            let masked = b1 & 0x80 != 0
            var length = Int(b1 & 0x7F)
            var offset = 2
            if length == 126 {
                guard buffer.count >= 4 else { return }
                length = Int(buffer[2]) << 8 | Int(buffer[3])
                offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return }
                length = 0
                for byte in buffer[2..<10] { length = length << 8 | Int(byte) }
                offset = 10
            }
            var maskKey: [UInt8] = []
            if masked {
                guard buffer.count >= offset + 4 else { return }
                maskKey = Array(buffer[offset..<(offset + 4)])
                offset += 4
            }
            guard buffer.count >= offset + length else { return }
            var payload = Array(buffer[offset..<(offset + length)])
            if masked {
                for index in payload.indices { payload[index] ^= maskKey[index % 4] }
            }
            buffer.removeSubrange(buffer.startIndex..<(offset + length))

            if !fin {
                session?.sendClose(code: 1002) // no fragmentation support, per the header comment
                shutdown()
                return
            }
            switch opcode {
            case 0x1: // text
                session?.onText?(String(decoding: payload, as: UTF8.self))
            case 0x8: // close
                session?.sendClose()
                shutdown()
                return
            case 0x9: // ping → pong
                session?.sendPong(Data(payload))
            default: // pong (0xA), continuation (0x0) — ignored
                break
            }
        }
    }
}
