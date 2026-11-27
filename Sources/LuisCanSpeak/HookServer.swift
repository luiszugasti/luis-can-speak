import Foundation
import Network

/// One hook call from Claude Code. Call `reply` exactly once. The hook script
/// prints the reply body, so Claude Code reads it as the hook's output.
final class HookRequest {
    let event: String
    let surface: String
    let body: [String: Any]
    private let connection: NWConnection
    private var replied = false

    init(event: String, surface: String, body: [String: Any], connection: NWConnection) {
        self.event = event
        self.surface = surface
        self.body = body
        self.connection = connection
    }

    /// Replies with a JSON object. An empty object means "do nothing", so
    /// Claude Code carries on as if the hook weren't there.
    func reply(_ json: [String: Any] = [:]) {
        guard !replied else { return }
        replied = true
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(data.count)\r\n"
        head += "Connection: close\r\n\r\n"
        let conn = connection
        conn.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// A tiny HTTP server on 127.0.0.1. Only the hook script talks to it.
final class HookServer {
    static let port: UInt16 = 47_321

    private var listener: NWListener?
    var onRequest: ((HookRequest) -> Void)?

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            self?.receive(on: conn, buffer: Data())
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = self.parse(buffer, conn: conn) {
                self.onRequest?(request)
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(on: conn, buffer: buffer)
        }
    }

    /// Returns a request once the whole body has arrived, or nil to keep reading.
    private func parse(_ buffer: Data, conn: NWConnection) -> HookRequest? {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headText = String(decoding: buffer[..<split.lowerBound], as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = split.upperBound
        guard buffer.count - bodyStart >= length else { return nil }

        let bodyData = buffer[bodyStart..<(bodyStart + length)]
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        let path = String(parts[1])
        let event = path.hasPrefix("/hook/") ? String(path.dropFirst("/hook/".count)) : path
        return HookRequest(event: event, surface: headers["x-cmux-surface"] ?? "", body: body, connection: conn)
    }
}
