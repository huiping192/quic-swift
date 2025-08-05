import Foundation
import Network
import QUICSwift
import Logging

@main
struct QUICServer {
    static func main() async {
        let logger = Logger(label: "QUICServer")
        
        do {
            let server = EchoServer()
            try await server.start(port: 8080)
        } catch {
            logger.error("Server failed to start: \(error)")
            exit(1)
        }
    }
}

class EchoServer {
    private let logger = Logger(label: "EchoServer")
    private var listener: UDPListener?
    private var clients: [String: UDPConnection] = [:]
    private let clientsQueue = DispatchQueue(label: "clients", attributes: .concurrent)
    
    func start(port: UInt16) async throws {
        logger.info("Starting Echo Server on port \(port)")
        
        listener = UDPListener()
        
        listener?.onNewConnection = { [weak self] connection in
            self?.handleNewClient(connection)
        }
        
        listener?.onDataReceived = { [weak self] data, endpoint in
            Task {
                await self?.handleData(data, from: endpoint)
            }
        }
        
        try await listener?.start(on: port)
        
        logger.info("Echo Server started successfully")
        logger.info("Press Ctrl+C to stop the server")
        
        // 保持服务器运行
        try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(Int.max))
        } onCancel: {
            self.stop()
        }
    }
    
    private func handleNewClient(_ connection: UDPConnection) {
        let clientId = UUID().uuidString
        logger.info("New client connected: \(clientId)")
        
        clientsQueue.async(flags: .barrier) {
            self.clients[clientId] = connection
        }
        
        connection.onStateChange = { [weak self] oldState, newState in
            self?.logger.info("Client \(clientId) state changed: \(oldState) -> \(newState)")
            
            switch newState {
            case .closed, .failed:
                self?.clientsQueue.async(flags: .barrier) {
                    self?.clients.removeValue(forKey: clientId)
                }
            default:
                break
            }
        }
        
        connection.onDataReceived = { [weak self] data, _ in
            Task {
                await self?.handleClientData(data, from: connection, clientId: clientId)
            }
        }
    }
    
    private func handleData(_ data: Data, from endpoint: NWEndpoint) async {
        logger.debug("Received \(data.count) bytes from \(endpoint)")
        
        guard let message = String(data: data, encoding: .utf8) else {
            logger.warning("Received invalid UTF-8 data from \(endpoint)")
            return
        }
        
        logger.info("Received message: '\(message)' from \(endpoint)")
        
        let echoMessage = "Echo: \(message)"
        let echoData = echoMessage.data(using: .utf8) ?? Data()
        
        do {
            try await listener?.send(data: echoData, to: endpoint)
            logger.info("Sent echo response to \(endpoint)")
        } catch {
            logger.error("Failed to send echo response to \(endpoint): \(error)")
        }
    }
    
    private func handleClientData(_ data: Data, from connection: UDPConnection, clientId: String) async {
        logger.debug("Received \(data.count) bytes from client \(clientId)")
        
        guard let message = String(data: data, encoding: .utf8) else {
            logger.warning("Received invalid UTF-8 data from client \(clientId)")
            return
        }
        
        logger.info("Client \(clientId) sent: '\(message)'")
        
        // Echo back the message with prefix
        let echoMessage = "Echo: \(message)"
        let echoData = echoMessage.data(using: .utf8) ?? Data()
        
        do {
            try await connection.send(data: echoData)
            logger.info("Sent echo response to client \(clientId)")
        } catch {
            logger.error("Failed to send echo response to client \(clientId): \(error)")
        }
    }
    
    private func stop() {
        logger.info("Stopping Echo Server")
        
        // 关闭所有客户端连接
        clientsQueue.sync {
            for (clientId, connection) in clients {
                logger.info("Closing connection to client \(clientId)")
                connection.close()
            }
            clients.removeAll()
        }
        
        // 停止监听器
        listener?.stop()
        listener = nil
        
        logger.info("Echo Server stopped")
    }
    
    deinit {
        stop()
    }
}