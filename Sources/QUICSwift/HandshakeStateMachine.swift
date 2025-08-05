import Foundation

// MARK: - 握手事件
public enum HandshakeEvent {
    case startHandshake
    case initialSent
    case initialReceived
    case handshakeSent
    case handshakeReceived
    case handshakeCompleted
    case handshakeFailed(Error)
    case timeout
    case reset
}

// MARK: - 握手角色
public enum HandshakeRole {
    case client
    case server
}

// MARK: - 握手状态机
public class HandshakeStateMachine {
    private var _state: HandshakeState = .idle
    private let role: HandshakeRole
    private let stateQueue = DispatchQueue(label: "handshake.state", qos: .userInitiated)
    private var timeoutTimer: Timer?
    private let timeoutInterval: TimeInterval = 30.0 // 30秒握手超时
    
    public var state: HandshakeState {
        return stateQueue.sync { _state }
    }
    
    public var onStateChange: ((HandshakeState, HandshakeState) -> Void)?
    public var onTimeout: (() -> Void)?
    
    public init(role: HandshakeRole) {
        self.role = role
    }
    
    deinit {
        cancelTimeout()
    }
    
    // MARK: - 状态转换
    public func transition(event: HandshakeEvent) -> Bool {
        return stateQueue.sync {
            let oldState = _state
            let newState = nextState(from: oldState, event: event, role: role)
            
            guard newState != oldState else {
                return false
            }
            
            _state = newState
            
            // 管理超时定时器
            manageTimeout(for: newState)
            
            // 通知状态变化
            onStateChange?(oldState, newState)
            
            return true
        }
    }
    
    private func nextState(from currentState: HandshakeState, event: HandshakeEvent, role: HandshakeRole) -> HandshakeState {
        switch (currentState, event, role) {
        // 客户端状态转换
        case (.idle, .startHandshake, .client):
            return .clientInitial
        case (.clientInitial, .initialSent, .client):
            return .clientInitial // 保持状态等待服务端响应
        case (.clientInitial, .initialReceived, .client):
            return .clientHandshake
        case (.clientHandshake, .handshakeSent, .client):
            return .clientHandshake // 保持状态等待握手完成
        case (.clientHandshake, .handshakeReceived, .client):
            return .completed
        case (.clientHandshake, .handshakeCompleted, .client):
            return .completed
            
        // 服务端状态转换
        case (.idle, .initialReceived, .server):
            return .serverInitial
        case (.serverInitial, .initialSent, .server):
            return .serverHandshake
        case (.serverHandshake, .handshakeSent, .server):
            return .serverHandshake // 保持状态等待客户端完成
        case (.serverHandshake, .handshakeReceived, .server):
            return .completed
        case (.serverHandshake, .handshakeCompleted, .server):
            return .completed
            
        // 通用错误和超时处理
        case (_, .handshakeFailed(let error), _):
            return .failed(error)
        case (_, .timeout, _):
            return .failed(QUICError.handshakeTimeout)
        case (_, .reset, _):
            return .idle
            
        // 无效转换，保持当前状态
        default:
            return currentState
        }
    }
    
    // MARK: - 超时管理
    private func manageTimeout(for state: HandshakeState) {
        cancelTimeout()
        
        switch state {
        case .clientInitial, .serverInitial, .clientHandshake, .serverHandshake:
            startTimeout()
        case .completed, .failed, .idle:
            break // 不需要超时
        }
    }
    
    private func startTimeout() {
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeoutInterval, repeats: false) { [weak self] _ in
            self?.handleTimeout()
        }
    }
    
    private func cancelTimeout() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }
    
    private func handleTimeout() {
        _ = transition(event: .timeout)
        onTimeout?()
    }
    
    // MARK: - 状态查询
    public var isCompleted: Bool {
        return state == .completed
    }
    
    public var isFailed: Bool {
        if case .failed = state {
            return true
        }
        return false
    }
    
    public var isInProgress: Bool {
        switch state {
        case .clientInitial, .serverInitial, .clientHandshake, .serverHandshake:
            return true
        default:
            return false
        }
    }
    
    public var canProcessPackets: Bool {
        return isInProgress || isCompleted
    }
}

// MARK: - 握手管理器
public class HandshakeManager {
    private let stateMachine: HandshakeStateMachine
    private let connectionIDManager: ConnectionIDManager
    private let versionNegotiation: VersionNegotiationStateMachine
    
    public var onHandshakeCompleted: (() -> Void)?
    public var onHandshakeFailed: ((Error) -> Void)?
    public var onPacketToSend: ((Data) -> Void)?
    
    public init(role: HandshakeRole, connectionIDManager: ConnectionIDManager) {
        self.stateMachine = HandshakeStateMachine(role: role)
        self.connectionIDManager = connectionIDManager
        self.versionNegotiation = VersionNegotiationStateMachine()
        
        setupCallbacks()
    }
    
    private func setupCallbacks() {
        stateMachine.onStateChange = { [weak self] oldState, newState in
            self?.handleStateChange(from: oldState, to: newState)
        }
        
        stateMachine.onTimeout = { [weak self] in
            self?.handleTimeout()
        }
        
        versionNegotiation.onStateChange = { [weak self] oldState, newState in
            self?.handleVersionNegotiationStateChange(from: oldState, to: newState)
        }
    }
    
    // MARK: - 握手流程控制
    public func startHandshake(destinationConnectionID: ConnectionID, sourceConnectionID: ConnectionID) {
        guard stateMachine.transition(event: .startHandshake) else {
            return
        }
        
        // 创建Initial包
        let initialPacket = createInitialPacket(
            destinationConnectionID: destinationConnectionID,
            sourceConnectionID: sourceConnectionID
        )
        
        onPacketToSend?(initialPacket)
        _ = stateMachine.transition(event: .initialSent)
    }
    
    public func handleIncomingPacket(_ packet: QUICPacket) -> Result<Void, Error> {
        // 首先处理版本协商
        if let version = packet.version {
            if version == QUICVersion.negotiation {
                return handleVersionNegotiationPacket(packet)
            } else if !VersionNegotiation.isVersionSupported(version) {
                return .failure(QUICError.unsupportedVersion(version))
            }
        }
        
        // 根据包类型处理握手包
        guard let packetType = packet.packetType else {
            return .failure(QUICError.unsupportedPacketType)
        }
        
        switch packetType {
        case .initial:
            return handleInitialPacket(packet)
        case .handshake:
            return handleHandshakePacket(packet)
        case .retry:
            return handleRetryPacket(packet)
        case .zeroRTT:
            return handleZeroRTTPacket(packet)
        }
    }
    
    // MARK: - 包处理方法
    private func handleInitialPacket(_ packet: QUICPacket) -> Result<Void, Error> {
        _ = stateMachine.transition(event: .initialReceived)
        
        // 服务端需要响应Initial包
        if case .serverInitial = stateMachine.state {
            let responsePacket = createInitialResponsePacket(for: packet)
            onPacketToSend?(responsePacket)
            _ = stateMachine.transition(event: .initialSent)
        }
        
        return .success(())
    }
    
    private func handleHandshakePacket(_ packet: QUICPacket) -> Result<Void, Error> {
        _ = stateMachine.transition(event: .handshakeReceived)
        
        // 处理握手完成逻辑
        if stateMachine.isCompleted {
            _ = stateMachine.transition(event: .handshakeCompleted)
        }
        
        return .success(())
    }
    
    private func handleRetryPacket(_ packet: QUICPacket) -> Result<Void, Error> {
        // Retry包处理逻辑
        // 需要使用新的连接ID重新发送Initial包
        return .success(())
    }
    
    private func handleZeroRTTPacket(_ packet: QUICPacket) -> Result<Void, Error> {
        // 0-RTT包处理逻辑
        return .success(())
    }
    
    private func handleVersionNegotiationPacket(_ packet: QUICPacket) -> Result<Void, Error> {
        let result = versionNegotiation.handleVersionNegotiationAsClient(packet: packet)
        
        switch result {
        case .success(_):
            // 使用选定的版本重新开始握手
            return .success(())
        case .failure(let error):
            _ = stateMachine.transition(event: .handshakeFailed(error))
            return .failure(error)
        }
    }
    
    // MARK: - 包创建方法
    private func createInitialPacket(destinationConnectionID: ConnectionID, sourceConnectionID: ConnectionID) -> Data {
        // 创建简单的Initial包载荷
        let payload = "QUIC Initial Handshake".data(using: .utf8) ?? Data()
        
        let packet = QUICPacket(
            headerForm: .long,
            packetType: .initial,
            version: QUICVersion.current,
            destinationConnectionID: destinationConnectionID,
            sourceConnectionID: sourceConnectionID,
            packetNumber: 0,
            payload: payload,
            token: nil
        )
        
        return packet.serialize()
    }
    
    private func createInitialResponsePacket(for incomingPacket: QUICPacket) -> Data {
        // 交换连接ID创建响应包
        let payload = "QUIC Initial Response".data(using: .utf8) ?? Data()
        
        let responsePacket = QUICPacket(
            headerForm: .long,
            packetType: .initial,
            version: incomingPacket.version,
            destinationConnectionID: incomingPacket.sourceConnectionID ?? ConnectionID.empty,
            sourceConnectionID: incomingPacket.destinationConnectionID,
            packetNumber: 0,
            payload: payload
        )
        
        return responsePacket.serialize()
    }
    
    private func createHandshakePacket(destinationConnectionID: ConnectionID, sourceConnectionID: ConnectionID) -> Data {
        let payload = "QUIC Handshake".data(using: .utf8) ?? Data()
        
        let packet = QUICPacket(
            headerForm: .long,
            packetType: .handshake,
            version: QUICVersion.current,
            destinationConnectionID: destinationConnectionID,
            sourceConnectionID: sourceConnectionID,
            packetNumber: 1,
            payload: payload
        )
        
        return packet.serialize()
    }
    
    // MARK: - 状态变化处理
    private func handleStateChange(from oldState: HandshakeState, to newState: HandshakeState) {
        switch newState {
        case .completed:
            onHandshakeCompleted?()
        case .failed(let error):
            onHandshakeFailed?(error)
        default:
            break
        }
    }
    
    private func handleTimeout() {
        let error = QUICError.handshakeTimeout
        onHandshakeFailed?(error)
    }
    
    private func handleVersionNegotiationStateChange(from oldState: VersionNegotiationStateMachine.State, to newState: VersionNegotiationStateMachine.State) {
        // 处理版本协商状态变化
    }
    
    // MARK: - 公共接口
    public var currentState: HandshakeState {
        return stateMachine.state
    }
    
    public var isCompleted: Bool {
        return stateMachine.isCompleted
    }
    
    public var isFailed: Bool {
        return stateMachine.isFailed
    }
    
    public func reset() {
        _ = stateMachine.transition(event: .reset)
        versionNegotiation.reset()
    }
}