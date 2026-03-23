import Foundation
import Network

public class WebSocketServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ws-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    public init(port: UInt16) throws {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            fatalError("Invalid port: \(port)")
        }
        listener = try NWListener(using: params, on: nwPort)

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                printError("WebSocket server listening on port \(port)")
            case .failed(let error):
                printError("WebSocket server failed: \(error)")
            default:
                break
            }
        }

        listener.start(queue: queue)
    }

    deinit {
        listener.cancel()
    }

    public func broadcast(_ data: Data) {
        lock.lock()
        let clients = connections
        lock.unlock()

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "ws-text",
            metadata: [metadata]
        )

        for connection in clients {
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { _ in }
            )
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                printError("WebSocket client connected")
            case .failed, .cancelled:
                printError("WebSocket client disconnected")
                self?.removeConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] _, context, _, error in
            if let error = error {
                printError("WebSocket receive error: \(error)")
                self?.removeConnection(connection)
                return
            }

            // Check for close frame
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata,
                metadata.opcode == .close
            {
                connection.cancel()
                return
            }

            // Continue receiving
            self?.receiveLoop(connection)
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        lock.lock()
        connections.removeAll { $0 === connection }
        lock.unlock()
    }
}
