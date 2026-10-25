import Foundation
import Network
import DomainCore

@MainActor
final class LocalDNS {
    static let port: UInt16 = 53535
    private var listeners: [NWListener] = []
    private let queue = DispatchQueue(label: "dev.dockerdomains.dns")

    func start() async throws {
        guard listeners.isEmpty else { return }
        do {
            for tcp in [false, true] {
                let parameters = tcp ? NWParameters.tcp : NWParameters.udp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: Self.port)!)
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [queue] connection in
                    connection.start(queue: queue)
                    if tcp { Self.receiveTCP(connection) } else { Self.receiveUDP(connection) }
                    queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
                }
                listeners.append(listener)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    // State updates arrive on one serial queue; the gate avoids resuming twice.
                    let gate = ListenerGate(continuation)
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready: gate.finish(nil)
                        case .failed(let error): gate.finish(error)
                        case .cancelled: gate.finish(DomainError("The local DNS listener was cancelled."))
                        default: break
                        }
                    }
                    listener.start(queue: queue)
                }
            }
        } catch {
            stop()
            throw DomainError("Local DNS could not listen on 127.0.0.1:\(Self.port). \(error.localizedDescription)")
        }
    }

    func stop() { listeners.forEach { $0.cancel() }; listeners.removeAll() }

    nonisolated private static func receiveUDP(_ connection: NWConnection) {
        connection.receiveMessage { data, _, _, error in
            guard error == nil, let data, let response = DNSMessage.response(to: data) else { connection.cancel(); return }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    nonisolated private static func receiveTCP(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, error in
            guard error == nil, let data, data.count == 2 else { connection.cancel(); return }
            let length = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
            guard length >= 12, length <= 4096 else { connection.cancel(); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                guard error == nil, let data, data.count == length, let response = DNSMessage.response(to: data) else { connection.cancel(); return }
                var framed = Data([UInt8(response.count >> 8), UInt8(response.count & 255)])
                framed.append(response)
                connection.send(content: framed, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

private final class ListenerGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}

