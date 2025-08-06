import Foundation

// MARK: - 连接级流量控制器
public class ConnectionFlowController {
    private var sendWindow: UInt64
    private var receiveWindow: UInt64
    private var maxReceiveWindow: UInt64
    private var bytesInFlight: UInt64 = 0
    private var bytesReceived: UInt64 = 0
    private var totalBytesSent: UInt64 = 0
    private var totalBytesReceived: UInt64 = 0
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
            totalBytesSent += bytesToConsume
        }
    }
    
    public func addSendCredit(bytes: UInt64) {
        lock.withLock {
            sendWindow += bytes
            bytesInFlight = bytesInFlight.saturatingSubtract(bytes)
        }
    }
    
    public func addReceiveCredit(bytes: Int) {
        lock.withLock {
            bytesReceived += UInt64(bytes)
            totalBytesReceived += UInt64(bytes)
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
    
    public func getStatistics() -> (sendWindow: UInt64, receiveWindow: UInt64, bytesInFlight: UInt64, totalSent: UInt64, totalReceived: UInt64) {
        return lock.withLock {
            return (sendWindow, receiveWindow, bytesInFlight, totalBytesSent, totalBytesReceived)
        }
    }
}

// MARK: - 综合流量控制器
public class FlowController {
    private let connectionFlowController: ConnectionFlowController
    private var streamFlowControllers: [UInt64: StreamFlowController] = [:]
    private let lock = NSLock()
    
    // 流量控制配置
    private let initialStreamWindow: UInt64
    private let maxStreamWindow: UInt64
    private let initialConnectionWindow: UInt64
    
    // 统计信息
    private var blockedStreams: Set<UInt64> = []
    private var totalBlocks: UInt64 = 0
    private var windowUpdatesSent: UInt64 = 0
    private var windowUpdatesReceived: UInt64 = 0
    
    // 回调
    public var onConnectionBlocked: (() -> Void)?
    public var onStreamBlocked: ((UInt64) -> Void)?
    public var onWindowUpdateNeeded: ((UInt64?, UInt64) -> Void)? // streamID?, increment
    
    public init(initialStreamWindow: UInt64 = 65536, 
                initialConnectionWindow: UInt64 = 1048576) { // 1MB
        self.initialStreamWindow = initialStreamWindow
        self.maxStreamWindow = initialStreamWindow * 16 // 最大16倍初始窗口
        self.initialConnectionWindow = initialConnectionWindow
        
        self.connectionFlowController = ConnectionFlowController(
            initialSendWindow: initialConnectionWindow,
            initialReceiveWindow: initialConnectionWindow
        )
    }
    
    // MARK: - 流级流量控制
    public func canSend(streamID: UInt64, bytes: Int) -> Bool {
        return lock.withLock {
            // 检查连接级窗口
            guard connectionFlowController.canSend(bytes: bytes) else {
                return false
            }
            
            // 检查流级窗口
            guard let streamController = streamFlowControllers[streamID] else {
                // 流不存在，创建新的流量控制器
                let controller = StreamFlowController(
                    initialSendWindow: initialStreamWindow,
                    initialReceiveWindow: initialStreamWindow
                )
                streamFlowControllers[streamID] = controller
                return controller.canSend(bytes: bytes)
            }
            
            return streamController.canSend(bytes: bytes)
        }
    }
    
    public func consumeCredit(streamID: UInt64, bytes: Int) {
        lock.withLock {
            // 消费连接级窗口
            connectionFlowController.consumeCredit(bytes: bytes)
            
            // 消费流级窗口
            if let streamController = streamFlowControllers[streamID] {
                streamController.consumeCredit(bytes: bytes)
            }
            
            // 检查是否被阻塞
            if !canSend(streamID: streamID, bytes: 1) {
                blockedStreams.insert(streamID)
                totalBlocks += 1
                onStreamBlocked?(streamID)
            }
        }
    }
    
    public func addCredit(streamID: UInt64, bytes: Int) {
        lock.withLock {
            if let streamController = streamFlowControllers[streamID] {
                streamController.addReceiveCredit(bytes: bytes)
            }
            
            connectionFlowController.addReceiveCredit(bytes: bytes)
            
            // 检查是否需要发送窗口更新
            checkAndSendWindowUpdates(streamID: streamID)
        }
    }
    
    // MARK: - 流量控制窗口管理
    public func getStreamWindow(streamID: UInt64) -> UInt64 {
        return lock.withLock {
            return streamFlowControllers[streamID]?.currentSendWindow ?? initialStreamWindow
        }
    }
    
    public func getConnectionWindow() -> UInt64 {
        return connectionFlowController.currentSendWindow
    }
    
    public func updateStreamWindow(streamID: UInt64, newWindow: UInt64) {
        lock.withLock {
            if let streamController = streamFlowControllers[streamID] {
                streamController.updateReceiveWindow(newWindow: newWindow)
            } else {
                let controller = StreamFlowController(
                    initialSendWindow: initialStreamWindow,
                    initialReceiveWindow: newWindow
                )
                streamFlowControllers[streamID] = controller
            }
            
            // 如果流之前被阻塞，现在可能可以发送了
            if blockedStreams.contains(streamID) && canSend(streamID: streamID, bytes: 1) {
                blockedStreams.remove(streamID)
            }
        }
    }
    
    public func updateConnectionWindow(newWindow: UInt64) {
        lock.withLock {
            connectionFlowController.updateReceiveWindow(newWindow: newWindow)
            
            // 检查之前被阻塞的流是否现在可以发送
            let previouslyBlocked = Array(blockedStreams)
            for streamID in previouslyBlocked {
                if canSend(streamID: streamID, bytes: 1) {
                    blockedStreams.remove(streamID)
                }
            }
        }
    }
    
    // MARK: - MAX_DATA和MAX_STREAM_DATA帧处理
    public func handleMaxData(_ increment: UInt64) {
        lock.withLock {
            connectionFlowController.addSendCredit(bytes: increment)
            windowUpdatesReceived += 1
            
            // 通知所有被阻塞的流
            let previouslyBlocked = Array(blockedStreams)
            for streamID in previouslyBlocked {
                if canSend(streamID: streamID, bytes: 1) {
                    blockedStreams.remove(streamID)
                }
            }
        }
    }
    
    public func handleMaxStreamData(_ frame: MaxStreamDataFrame) {
        lock.withLock {
            if let streamController = streamFlowControllers[frame.streamID] {
                let currentWindow = streamController.currentSendWindow
                let increment = frame.maxStreamData.saturatingSubtract(currentWindow)
                streamController.addSendCredit(bytes: increment)
                windowUpdatesReceived += 1
                
                // 如果流之前被阻塞，现在可能可以发送了
                if blockedStreams.contains(frame.streamID) && canSend(streamID: frame.streamID, bytes: 1) {
                    blockedStreams.remove(frame.streamID)
                }
            }
        }
    }
    
    // MARK: - 窗口更新生成
    private func checkAndSendWindowUpdates(streamID: UInt64) {
        // 检查流级窗口更新
        if let streamController = streamFlowControllers[streamID],
           streamController.shouldSendWindowUpdate() {
            let increment = streamController.generateWindowUpdate()
            windowUpdatesSent += 1
            onWindowUpdateNeeded?(streamID, increment)
        }
        
        // 检查连接级窗口更新
        if connectionFlowController.shouldSendWindowUpdate() {
            let increment = connectionFlowController.generateWindowUpdate()
            windowUpdatesSent += 1
            onWindowUpdateNeeded?(nil, increment)
        }
    }
    
    // MARK: - 流生命周期管理
    public func createStreamController(streamID: UInt64) {
        lock.withLock {
            guard streamFlowControllers[streamID] == nil else { return }
            
            let controller = StreamFlowController(
                initialSendWindow: initialStreamWindow,
                initialReceiveWindow: initialStreamWindow
            )
            streamFlowControllers[streamID] = controller
        }
    }
    
    public func removeStreamController(streamID: UInt64) {
        lock.withLock {
            streamFlowControllers.removeValue(forKey: streamID)
            blockedStreams.remove(streamID)
        }
    }
    
    // MARK: - 背压处理
    public func getBlockedStreams() -> Set<UInt64> {
        return lock.withLock {
            return blockedStreams
        }
    }
    
    public func isStreamBlocked(streamID: UInt64) -> Bool {
        return lock.withLock {
            return blockedStreams.contains(streamID)
        }
    }
    
    public func isConnectionBlocked() -> Bool {
        return !connectionFlowController.canSend(bytes: 1)
    }
    
    // MARK: - 统计信息
    public func getFlowControlStatistics() -> FlowControlStatistics {
        return lock.withLock {
            let connectionStats = connectionFlowController.getStatistics()
            
            let streamWindows = streamFlowControllers.mapValues { controller in
                (send: controller.currentSendWindow, receive: controller.currentReceiveWindow)
            }
            
            return FlowControlStatistics(
                connectionSendWindow: connectionStats.sendWindow,
                connectionReceiveWindow: connectionStats.receiveWindow,
                connectionBytesInFlight: connectionStats.bytesInFlight,
                totalBytesSent: connectionStats.totalSent,
                totalBytesReceived: connectionStats.totalReceived,
                activeStreamControllers: streamFlowControllers.count,
                blockedStreams: blockedStreams.count,
                totalBlocks: totalBlocks,
                windowUpdatesSent: windowUpdatesSent,
                windowUpdatesReceived: windowUpdatesReceived,
                streamWindows: streamWindows
            )
        }
    }
    
    public func debugInfo() -> String {
        let stats = getFlowControlStatistics()
        
        return """
        Flow Control Info:
          Connection Windows:
            Send: \(stats.connectionSendWindow) bytes
            Receive: \(stats.connectionReceiveWindow) bytes
            In Flight: \(stats.connectionBytesInFlight) bytes
          
          Stream Controllers: \(stats.activeStreamControllers)
          Blocked Streams: \(stats.blockedStreams)
          Total Blocks: \(stats.totalBlocks)
          
          Window Updates:
            Sent: \(stats.windowUpdatesSent)
            Received: \(stats.windowUpdatesReceived)
          
          Traffic:
            Total Sent: \(stats.totalBytesSent) bytes
            Total Received: \(stats.totalBytesReceived) bytes
        """
    }
    
    // MARK: - 清理和维护
    public func performMaintenance() {
        lock.withLock {
            // 清理不活跃的流控制器（可选）
            // 这里可以添加基于时间的清理逻辑
        }
    }
}

// MARK: - 流量控制统计信息
public struct FlowControlStatistics {
    public let connectionSendWindow: UInt64
    public let connectionReceiveWindow: UInt64
    public let connectionBytesInFlight: UInt64
    public let totalBytesSent: UInt64
    public let totalBytesReceived: UInt64
    public let activeStreamControllers: Int
    public let blockedStreams: Int
    public let totalBlocks: UInt64
    public let windowUpdatesSent: UInt64
    public let windowUpdatesReceived: UInt64
    public let streamWindows: [UInt64: (send: UInt64, receive: UInt64)]
    
    public var debugDescription: String {
        return """
        FlowControlStats:
          Connection: send=\(connectionSendWindow), recv=\(connectionReceiveWindow), flight=\(connectionBytesInFlight)
          Streams: active=\(activeStreamControllers), blocked=\(blockedStreams)
          Updates: sent=\(windowUpdatesSent), received=\(windowUpdatesReceived)
          Traffic: sent=\(totalBytesSent), received=\(totalBytesReceived)
        """
    }
}

// MARK: - 流量控制帧
public struct MaxDataFrame {
    public let maxData: UInt64
    
    public init(maxData: UInt64) {
        self.maxData = maxData
    }
    
    public func serialize() -> Data {
        var builder = PacketBuilder()
        builder.writeUInt8(0x10) // MAX_DATA frame type
        builder.writeVariableInt(maxData)
        return builder.build()
    }
    
    public static func parse(from data: Data) throws -> MaxDataFrame {
        var parser = PacketParser(data: data)
        let frameType = try parser.readUInt8()
        guard frameType == 0x10 else {
            throw QUICError.unsupportedFrameType
        }
        
        let maxData = try parser.readVariableInt()
        return MaxDataFrame(maxData: maxData)
    }
}

public struct DataBlockedFrame {
    public let dataLimit: UInt64
    
    public init(dataLimit: UInt64) {
        self.dataLimit = dataLimit
    }
    
    public func serialize() -> Data {
        var builder = PacketBuilder()
        builder.writeUInt8(0x14) // DATA_BLOCKED frame type
        builder.writeVariableInt(dataLimit)
        return builder.build()
    }
    
    public static func parse(from data: Data) throws -> DataBlockedFrame {
        var parser = PacketParser(data: data)
        let frameType = try parser.readUInt8()
        guard frameType == 0x14 else {
            throw QUICError.unsupportedFrameType
        }
        
        let dataLimit = try parser.readVariableInt()
        return DataBlockedFrame(dataLimit: dataLimit)
    }
}