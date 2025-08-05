import Foundation
import Network
import QUICSwift
import Logging

@main
struct QUICClient {
    static func main() async {
        let logger = Logger(label: "QUICClient")
        
        guard CommandLine.arguments.count >= 2 else {
            print("Usage: QUICClient <server_host> [port]")
            print("Example: QUICClient localhost 8080")
            exit(1)
        }
        
        let host = CommandLine.arguments[1]
        let port = CommandLine.arguments.count > 2 ? UInt16(CommandLine.arguments[2]) ?? 8080 : 8080
        
        do {
            let client = EchoClient()
            try await client.start(host: host, port: port)
        } catch {
            logger.error("Client failed: \(error)")
            exit(1)
        }
    }
}

class EchoClient {
    private let logger = Logger(label: "EchoClient")
    private var connection: UDPConnection?
    
    func start(host: String, port: UInt16) async throws {
        logger.info("Starting Echo Client, connecting to \(host):\(port)")
        
        // 创建端点
        guard let portObj = NWEndpoint.Port(rawValue: port) else {
            throw NetworkError.invalidEndpoint
        }
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: portObj)
        
        // 创建连接
        connection = UDPConnection()
        
        connection?.onStateChange = { [weak self] oldState, newState in
            self?.logger.info("Connection state changed: \(oldState) -> \(newState)")
        }
        
        connection?.onDataReceived = { [weak self] data, endpoint in
            self?.handleReceivedData(data, from: endpoint)
        }
        
        // 连接到服务器
        try await connection?.connect(to: endpoint)
        logger.info("Connected to server successfully")
        
        // 启动交互式会话
        await startInteractiveSession()
    }
    
    private func startInteractiveSession() async {
        logger.info("Interactive session started. Type messages to send (type 'quit' to exit):")
        
        while true {
            print("> ", terminator: "")
            fflush(stdout)
            
            guard let input = readLine() else {
                break
            }
            
            let message = input.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if message.lowercased() == "quit" {
                logger.info("Quitting...")
                break
            }
            
            if message.isEmpty {
                continue
            }
            
            do {
                try await sendMessage(message)
            } catch {
                logger.error("Failed to send message: \(error)")
            }
        }
        
        connection?.close()
    }
    
    private func sendMessage(_ message: String) async throws {
        guard let connection = connection else {
            throw NetworkError.notConnected
        }
        
        guard let data = message.data(using: .utf8) else {
            logger.error("Failed to encode message as UTF-8")
            return
        }
        
        logger.info("Sending message: '\(message)'")
        try await connection.send(data: data)
    }
    
    private func handleReceivedData(_ data: Data, from endpoint: NWEndpoint?) {
        guard let message = String(data: data, encoding: .utf8) else {
            logger.warning("Received invalid UTF-8 data")
            return
        }
        
        logger.info("Received response: '\(message)'")
        print("Server: \(message)")
    }
}

// 辅助类用于测试不同场景
class TestClient {
    private let logger = Logger(label: "TestClient")
    
    func runPerformanceTest(host: String, port: UInt16, messageCount: Int = 100) async throws {
        logger.info("Starting performance test with \(messageCount) messages")
        
        guard let portObj = NWEndpoint.Port(rawValue: port) else {
            throw NetworkError.invalidEndpoint
        }
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: portObj)
        let connection = UDPConnection()
        
        var receivedCount = 0
        let startTime = Date()
        
        connection.onDataReceived = { data, _ in
            receivedCount += 1
            if receivedCount == messageCount {
                let endTime = Date()
                let duration = endTime.timeIntervalSince(startTime)
                self.logger.info("Performance test completed:")
                self.logger.info("- Messages: \(messageCount)")
                self.logger.info("- Duration: \(String(format: "%.2f", duration))s")
                self.logger.info("- Rate: \(String(format: "%.2f", Double(messageCount) / duration)) msg/s")
            }
        }
        
        try await connection.connect(to: endpoint)
        
        logger.info("Sending \(messageCount) messages...")
        
        for i in 1...messageCount {
            let message = "Test message \(i)"
            let data = message.data(using: .utf8) ?? Data()
            
            try await connection.send(data: data)
            
            if i % 10 == 0 {
                logger.info("Sent \(i)/\(messageCount) messages")
            }
        }
        
        // 等待所有响应
        while receivedCount < messageCount {
            try await Task.sleep(for: .milliseconds(10))
        }
        
        connection.close()
    }
    
    func runConcurrentTest(host: String, port: UInt16, clientCount: Int = 10, messagesPerClient: Int = 10) async throws {
        logger.info("Starting concurrent test with \(clientCount) clients, \(messagesPerClient) messages each")
        
        let startTime = Date()
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for clientId in 1...clientCount {
                group.addTask {
                    try await self.runSingleClientTest(
                        host: host,
                        port: port,
                        clientId: clientId,
                        messageCount: messagesPerClient
                    )
                }
            }
            
            try await group.waitForAll()
        }
        
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        let totalMessages = clientCount * messagesPerClient
        
        logger.info("Concurrent test completed:")
        logger.info("- Clients: \(clientCount)")
        logger.info("- Messages per client: \(messagesPerClient)")
        logger.info("- Total messages: \(totalMessages)")
        logger.info("- Duration: \(String(format: "%.2f", duration))s")
        logger.info("- Rate: \(String(format: "%.2f", Double(totalMessages) / duration)) msg/s")
    }
    
    private func runSingleClientTest(host: String, port: UInt16, clientId: Int, messageCount: Int) async throws {
        guard let portObj = NWEndpoint.Port(rawValue: port) else {
            throw NetworkError.invalidEndpoint
        }
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: portObj)
        let connection = UDPConnection()
        
        var receivedCount = 0
        
        connection.onDataReceived = { _, _ in
            receivedCount += 1
        }
        
        try await connection.connect(to: endpoint)
        
        for i in 1...messageCount {
            let message = "Client \(clientId) message \(i)"
            let data = message.data(using: .utf8) ?? Data()
            try await connection.send(data: data)
        }
        
        // 等待所有响应
        while receivedCount < messageCount {
            try await Task.sleep(for: .milliseconds(1))
        }
        
        connection.close()
        logger.debug("Client \(clientId) completed")
    }
}