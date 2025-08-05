import Foundation
import Network
import Logging

public class UDPConnection: UDPConnectionProtocol {
    private var connection: NWConnection?
    private let stateMachine = ConnectionStateMachine()
    private let logger = Logger(label: "UDPConnection")
    private let timeoutInterval: TimeInterval = 10.0
    
    public var state: ConnectionState {
        return stateMachine.state
    }
    
    public var onStateChange: ((ConnectionState, ConnectionState) -> Void)? {
        get { stateMachine.onStateChange }
        set { stateMachine.onStateChange = newValue }
    }
    
    public var onDataReceived: ((Data, NWEndpoint?) -> Void)?
    
    public init() {
        setupStateChangeHandler()
    }
    
    private func setupStateChangeHandler() {
        stateMachine.onStateChange = { [weak self] oldState, newState in
            self?.logger.info("Connection state changed: \(oldState) -> \(newState)")
        }
    }
    
    public func connect(to endpoint: NWEndpoint) async throws {
        logger.info("Attempting to connect to \(endpoint)")
        
        guard stateMachine.transition(event: .startConnecting) else {
            throw ConnectionError.invalidState
        }
        
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        connection = NWConnection(to: endpoint, using: parameters)
        
        guard let connection = connection else {
            _ = stateMachine.transition(event: .connectionFailed(NetworkError.invalidEndpoint))
            throw NetworkError.invalidEndpoint
        }
        
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.waitForConnection(connection)
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.timeoutInterval * 1_000_000_000))
                throw NetworkError.sendTimeout
            }
            
            connection.start(queue: .global(qos: .userInitiated))
            
            try await group.next()
            group.cancelAll()
        }
    }
    
    private func waitForConnection(_ connection: NWConnection) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { [weak self] newState in
                switch newState {
                case .ready:
                    _ = self?.stateMachine.transition(event: .connectionEstablished)
                    self?.startReceiving(connection)
                    continuation.resume()
                case .failed(let error):
                    _ = self?.stateMachine.transition(event: .connectionFailed(error))
                    continuation.resume(throwing: error)
                case .cancelled:
                    _ = self?.stateMachine.transition(event: .connectionClosed)
                    continuation.resume(throwing: NetworkError.connectionClosed)
                default:
                    break
                }
            }
        }
    }
    
    public func send(data: Data) async throws {
        guard state.canSend else {
            throw NetworkError.notConnected
        }
        
        guard let connection = connection else {
            throw NetworkError.notConnected
        }
        
        logger.debug("Sending \(data.count) bytes")
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    self.logger.error("Send failed: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    public func send(data: Data, to endpoint: NWEndpoint) async throws {
        throw NetworkError.invalidEndpoint
    }
    
    public func receive() async throws -> (Data, NWEndpoint?) {
        guard state.canReceive else {
            throw NetworkError.notConnected
        }
        
        guard let connection = connection else {
            throw NetworkError.notConnected
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error {
                    self.logger.error("Receive failed: \(error)")
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: (data, nil))
                } else if isComplete {
                    continuation.resume(throwing: NetworkError.connectionClosed)
                } else {
                    continuation.resume(throwing: NetworkError.receiveTimeout)
                }
            }
        }
    }
    
    private func startReceiving(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.onDataReceived?(data, nil)
            }
            
            if let error = error {
                self?.logger.error("Receive error: \(error)")
                _ = self?.stateMachine.transition(event: .connectionFailed(error))
                return
            }
            
            if isComplete {
                _ = self?.stateMachine.transition(event: .connectionClosed)
                return
            }
            
            if self?.state.canReceive == true {
                self?.startReceiving(connection)
            }
        }
    }
    
    public func close() {
        logger.info("Closing connection")
        
        _ = stateMachine.transition(event: .startClosing)
        connection?.cancel()
        connection = nil
        _ = stateMachine.transition(event: .connectionClosed)
    }
    
    deinit {
        close()
    }
}

public class UDPListener: UDPListenerProtocol {
    private var listener: NWListener?
    private let logger = Logger(label: "UDPListener")
    private var isRunning = false
    
    public var onNewConnection: ((UDPConnection) -> Void)?
    public var onDataReceived: ((Data, NWEndpoint) -> Void)?
    
    public init() {}
    
    public func start(on port: UInt16) async throws {
        logger.info("Starting UDP listener on port \(port)")
        
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            logger.error("Failed to create listener: \(error)")
            throw NetworkError.bindFailed(error.localizedDescription)
        }
        
        guard let listener = listener else {
            throw NetworkError.listenerFailed("Failed to create listener")
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] newState in
                switch newState {
                case .ready:
                    self?.isRunning = true
                    self?.logger.info("UDP listener is ready")
                    continuation.resume()
                case .failed(let error):
                    self?.logger.error("UDP listener failed: \(error)")
                    continuation.resume(throwing: NetworkError.listenerFailed(error.localizedDescription))
                case .cancelled:
                    self?.isRunning = false
                    self?.logger.info("UDP listener cancelled")
                default:
                    break
                }
            }
            
            listener.newConnectionHandler = { [weak self] newConnection in
                self?.handleNewConnection(newConnection)
            }
            
            listener.start(queue: .global(qos: .userInitiated))
        }
    }
    
    private func handleNewConnection(_ nwConnection: NWConnection) {
        logger.info("New connection from \(nwConnection.endpoint)")
        
        let udpConnection = UDPConnection()
        // TODO: Set up the connection with existing NWConnection
        onNewConnection?(udpConnection)
    }
    
    public func send(data: Data, to endpoint: NWEndpoint) async throws {
        throw NetworkError.invalidEndpoint
    }
    
    public func stop() {
        logger.info("Stopping UDP listener")
        listener?.cancel()
        listener = nil
        isRunning = false
    }
    
    deinit {
        stop()
    }
}