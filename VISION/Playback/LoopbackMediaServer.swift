import Foundation
import Network

/// Feeds the VLC engine decrypted bytes without ever writing plaintext to disk.
///
/// VLC can't use AVFoundation's resource loader, so while a VLC video is open we run a
/// tiny HTTP server bound to the loopback interface only (127.0.0.1 — not reachable from
/// the network). It serves byte ranges decrypted on demand from the vault file, under an
/// unguessable 256-bit path, and is shut down as soon as the player closes.
final class LoopbackMediaServer: @unchecked Sendable {
    private let reader: VaultFileReader
    private let token: String
    private let queue = DispatchQueue(label: "vision.loopback", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let chunk = 256 * 1024

    init(reader: VaultFileReader) {
        self.reader = reader
        token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let token = self.token

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    if let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/media") {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: URLError(.cannotFindHost))
                    }
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    // MARK: Connections (all on `queue`)

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receiveHeader(connection, buffer: Data())
    }

    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveHeader(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD", parts[1].hasPrefix("/\(token)/") else {
            sendHead(connection, status: "404 Not Found", headers: ["Content-Length": "0"], thenBody: nil)
            return
        }
        let total = reader.plaintextLength
        guard total > 0 else {
            sendHead(connection, status: "200 OK", headers: ["Content-Length": "0"], thenBody: nil)
            return
        }

        var start: UInt64 = 0
        var end: UInt64 = total - 1
        var partial = false
        if let line = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let spec = line.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces),
           !spec.contains(",") {
            let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if bounds.count == 2 {
                if bounds[0].isEmpty, let suffix = UInt64(bounds[1]), suffix > 0 {
                    start = total > suffix ? total - suffix : 0
                } else if let from = UInt64(bounds[0]) {
                    start = from
                    if let to = UInt64(bounds[1]) { end = min(to, total - 1) }
                }
                partial = true
            }
        }
        guard start <= end, start < total else {
            sendHead(connection, status: "416 Range Not Satisfiable",
                     headers: ["Content-Range": "bytes */\(total)", "Content-Length": "0"], thenBody: nil)
            return
        }

        var headers = ["Content-Type": "application/octet-stream",
                       "Accept-Ranges": "bytes",
                       "Content-Length": "\(end - start + 1)"]
        if partial { headers["Content-Range"] = "bytes \(start)-\(end)/\(total)" }
        sendHead(connection, status: partial ? "206 Partial Content" : "200 OK", headers: headers,
                 thenBody: parts[0] == "GET" ? (start, end) : nil)
    }

    private func sendHead(_ connection: NWConnection, status: String, headers: [String: String], thenBody body: (UInt64, UInt64)?) {
        var text = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers { text += "\(key): \(value)\r\n" }
        text += "Connection: close\r\n\r\n"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self, let body else {
                self?.finish(connection)
                return
            }
            self.stream(connection, from: body.0, to: body.1)
        })
    }

    /// Sends one chunk at a time and waits for it to be consumed (natural back-pressure:
    /// memory stays flat, and a seek simply closes this connection).
    private func stream(_ connection: NWConnection, from offset: UInt64, to end: UInt64) {
        guard offset <= end else {
            finish(connection)
            return
        }
        let length = Int(min(UInt64(chunk), end - offset + 1))
        guard let data = try? reader.read(offset: offset, length: length), !data.isEmpty else {
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else {
                connection.cancel()
                return
            }
            self.stream(connection, from: offset + UInt64(data.count), to: end)
        })
    }

    private func finish(_ connection: NWConnection) {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
