import Foundation

// MARK: - 流量控制器
public class StreamFlowController {
    private var sendWindow: UInt64
    private var receiveWindow: UInt64
    private var maxReceiveWindow: UInt64
    private var bytesInFlight: UInt64 = 0
    private var bytesReceived: UInt64 = 0
    private let lock = NSLock()
    
    public init(initialSendWindow: UInt64, initialReceiveWindow: UInt64) {
        self.sendWindow = initialSendWindow
        self.receiveWindow = initialReceiveWindow
        self.maxReceiveWindow = initialReceiveWindow
    }
    
    public func canSend(bytes: Int) -> Bool {
        return lock.withLock {
            return UInt64(bytes) <= sendWindow
        }
    }
    
    public func consumeCredit(bytes: Int) {
        lock.withLock {
            let bytesToConsume = min(UInt64(bytes), sendWindow)
            sendWindow -= bytesToConsume
            bytesInFlight += bytesToConsume
        }
    }
    
    public func addSendCredit(bytes: UInt64) {
        lock.withLock {
            sendWindow += bytes
        }
    }
    
    public func addReceiveCredit(bytes: Int) {
        lock.withLock {
            bytesReceived += UInt64(bytes)
            receiveWindow = receiveWindow.saturatingSubtract(UInt64(bytes))
        }
    }
    
    public func updateReceiveWindow(newWindow: UInt64) {
        lock.withLock {
            receiveWindow = newWindow
        }
    }
    
    public var currentSendWindow: UInt64 {
        return lock.withLock { sendWindow }
    }
    
    public var currentReceiveWindow: UInt64 {
        return lock.withLock { receiveWindow }
    }
    
    public func shouldSendWindowUpdate() -> Bool {
        return lock.withLock {
            return receiveWindow <= maxReceiveWindow / 2
        }
    }
    
    public func generateWindowUpdate() -> UInt64 {
        return lock.withLock {
            let newWindow = maxReceiveWindow
            let increment = newWindow - receiveWindow
            receiveWindow = newWindow
            return increment
        }
    }
}

// MARK: - QUIC流
public class QUICStream {
    public let id: UInt64
    public let type: StreamType
    public let initiator: StreamInitiator
    private(set) public var state: StreamState = .idle
    private let createdAt: Date = Date()
    
    private var sendBuffer: StreamBuffer
    private var receiveBuffer: StreamBuffer
    private var flowController: StreamFlowController
    private let stateQueue = DispatchQueue(label: "stream.state.\(UUID().uuidString)", qos: .userInitiated)
    
    // 回调
    public var onDataAvailable: (() -> Void)?
    public var onWritable: (() -> Void)?
    public var onStateChange: ((StreamState, StreamState) -> Void)?
    public var onError: ((Error) -> Void)?
    
    // 连接回调
    public var notifyConnectionForSend: (() async -> Void)?
    public var notifyConnectionForReset: ((UInt64) async -> Void)?
    public var notifyConnectionForWindowUpdate: ((UInt64, UInt64) async -> Void)?
    
    public init(id: UInt64, type: StreamType, initialWindowSize: UInt64 = 65536) {
        self.id = id
        self.type = type
        self.initiator = StreamInitiator.fromStreamID(id)
        self.sendBuffer = StreamBuffer()
        self.receiveBuffer = StreamBuffer()
        self.flowController = StreamFlowController(
            initialSendWindow: initialWindowSize,
            initialReceiveWindow: initialWindowSize
        )
        
        self.state = .open
    }
    
    // MARK: - 数据写入
    public func write(data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async {
                do {
                    guard self.canWrite() else {
                        continuation.resume(throwing: StreamError.streamNotWritable)
                        return
                    }
                    
                    guard self.flowController.canSend(bytes: data.count) else {
                        continuation.resume(throwing: StreamError.flowControlBlocked)
                        return
                    }
                    
                    try self.sendBuffer.append(data)
                    self.flowController.consumeCredit(bytes: data.count)
                    
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        
        // 通知连接发送数据
        await notifyConnectionForSend?()
    }
    
    public func writeWithoutBlocking(data: Data) throws {
        try stateQueue.sync {
            guard canWrite() else {
                throw StreamError.streamNotWritable
            }
            
            guard flowController.canSend(bytes: data.count) else {
                throw StreamError.flowControlBlocked
            }
            
            try sendBuffer.append(data)
            flowController.consumeCredit(bytes: data.count)
        }
    }
    
    // MARK: - 数据读取
    public func read() async throws -> Data? {
        return try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                do {
                    guard self.canRead() else {
                        continuation.resume(returning: nil)
                        return
                    }
                    
                    let data = self.receiveBuffer.read()
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    public func readUpTo(_ maxBytes: Int) async throws -> Data? {
        return try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                do {
                    guard self.canRead() else {
                        continuation.resume(returning: nil)
                        return
                    }
                    
                    let data = self.receiveBuffer.readUpTo(maxBytes)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    public func readWithoutBlocking() -> Data? {
        return stateQueue.sync {
            guard canRead() else {
                return nil
            }
            
            return receiveBuffer.read()
        }
    }
    
    // MARK: - 流帧处理
    public func handleStreamFrame(_ frame: StreamFrame) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async {
                do {
                    // 验证流状态
                    guard self.state == .open || self.state == .halfClosed else {
                        continuation.resume(throwing: StreamError.invalidStreamState)
                        return
                    }
                    
                    // 检查偏移量
                    guard self.receiveBuffer.canAcceptOffset(frame.offset) else {
                        // 可能是重复数据，忽略
                        continuation.resume()
                        return
                    }
                    
                    // 添加数据到接收缓冲区
                    try self.receiveBuffer.addData(frame.data, at: frame.offset)
                    
                    // 更新流量控制
                    self.flowController.addReceiveCredit(bytes: frame.data.count)
                    
                    // 处理FIN标志
                    if frame.fin {
                        self.receiveBuffer.markComplete()
                        self.updateState(event: .receivedFin)
                    }
                    
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        
        // 检查是否需要发送窗口更新
        if flowController.shouldSendWindowUpdate() {
            let increment = flowController.generateWindowUpdate()
            await notifyConnectionForWindowUpdate?(id, increment)
        }
        
        // 通知数据可用
        onDataAvailable?()
    }
    
    // MARK: - 获取要发送的数据
    public func getDataToSend(maxBytes: Int) -> StreamFrame? {
        return stateQueue.sync {
            // 首先尝试获取待发送的数据
            if let (data, offset) = sendBuffer.getDataToSend(maxBytes: maxBytes) {
                // 数据帧不应该带FIN标志，FIN会在单独的帧中发送
                return StreamFrame(
                    streamID: id,
                    offset: offset,
                    data: data,
                    fin: false,
                    length: UInt64(data.count)
                )
            } else if sendBuffer.isSendCompleted && sendBuffer.sendBufferSize == 0 {
                // 所有数据已发送完毕，现在发送FIN帧
                return StreamFrame(
                    streamID: id,
                    offset: sendBuffer.sendOffset,
                    data: Data(),
                    fin: true,
                    length: 0
                )
            }
            
            return nil
        }
    }
    
    public func markDataSent(bytes: Int) {
        stateQueue.sync {
            sendBuffer.markSent(bytes: bytes)
        }
    }
    
    // MARK: - 流控制
    public func close() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async {
                guard self.state == .open else {
                    continuation.resume(throwing: StreamError.streamAlreadyClosed)
                    return
                }
                
                self.sendBuffer.markSendComplete()
                self.updateState(event: .sentFin)
                continuation.resume()
            }
        }
        
        await notifyConnectionForSend?()
    }
    
    public func reset(errorCode: UInt64) async throws {
        await withCheckedContinuation { continuation in
            stateQueue.async {
                self.state = .resetSent
                self.sendBuffer.clear()
                self.receiveBuffer.clear()
                continuation.resume()
            }
        }
        
        await notifyConnectionForReset?(errorCode)
    }
    
    public func handleReset(errorCode: UInt64, finalSize: UInt64) {
        stateQueue.sync {
            state = .resetReceived
            sendBuffer.clear()
            receiveBuffer.clear()
        }
    }
    
    // MARK: - 流量控制更新
    public func updateSendWindow(increment: UInt64) {
        stateQueue.sync {
            flowController.addSendCredit(bytes: increment)
        }
        
        onWritable?()
    }
    
    // MARK: - 状态查询
    public func canWrite() -> Bool {
        switch state {
        case .open:
            return !sendBuffer.isCompleted && flowController.canSend(bytes: 1)
        default:
            return false
        }
    }
    
    public func canRead() -> Bool {
        switch state {
        case .open, .halfClosed:
            return receiveBuffer.hasData()
        default:
            return false
        }
    }
    
    public var isActive: Bool {
        return stateQueue.sync {
            switch state {
            case .open, .halfClosed:
                return true
            default:
                return false
            }
        }
    }
    
    public var isClosed: Bool {
        return stateQueue.sync {
            switch state {
            case .closed, .resetSent, .resetReceived:
                return true
            default:
                return false
            }
        }
    }
    
    // MARK: - 内部方法
    private func updateState(event: StreamEvent) {
        let oldState = state
        
        switch (state, event) {
        case (.idle, .created):
            state = .open
        case (.open, .sentFin):
            state = .halfClosed
        case (.open, .receivedFin):
            state = .halfClosed
        case (.halfClosed, .receivedFin), (.halfClosed, .sentFin):
            state = .closed
        case (_, .reset):
            state = .resetReceived
        default:
            break // 无效的状态转换
        }
        
        if oldState != state {
            onStateChange?(oldState, state)
        }
    }
    
    // MARK: - 调试和统计
    public var debugInfo: StreamDebugInfo {
        return stateQueue.sync {
            let (totalReceived, totalSent, _, _) = receiveBuffer.getStatistics()
            
            return StreamDebugInfo(
                id: id,
                state: state,
                sendBufferSize: sendBuffer.currentSize,
                receiveBufferSize: receiveBuffer.currentSize,
                flowControlWindow: flowController.currentSendWindow,
                bytesReceived: totalReceived,
                bytesSent: totalSent,
                createdAt: createdAt
            )
        }
    }
    
    public func getFlowControlInfo() -> (sendWindow: UInt64, receiveWindow: UInt64) {
        return stateQueue.sync {
            return (
                sendWindow: flowController.currentSendWindow,
                receiveWindow: flowController.currentReceiveWindow
            )
        }
    }
    
    public var hasDataToSend: Bool {
        return stateQueue.sync {
            return !sendBuffer.isEmpty
        }
    }
    
    public var hasPendingData: Bool {
        return stateQueue.sync {
            return receiveBuffer.hasData()
        }
    }
}

// MARK: - 扩展方法
extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        return self > other ? self - other : 0
    }
}