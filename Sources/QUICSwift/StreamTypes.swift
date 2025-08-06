import Foundation

// MARK: - 流类型定义
public enum StreamType {
    case bidirectional
    case unidirectional
    
    static func fromStreamID(_ streamID: UInt64) -> StreamType {
        return (streamID & 0x02) == 0 ? .bidirectional : .unidirectional
    }
}

// MARK: - 流发起者
public enum StreamInitiator {
    case client
    case server
    
    static func fromStreamID(_ streamID: UInt64) -> StreamInitiator {
        return (streamID & 0x01) == 0 ? .client : .server
    }
}

// MARK: - 流状态
public enum StreamState: Equatable {
    case idle           // 流未创建
    case open           // 流已创建，可读写
    case halfClosed     // 一个方向已关闭
    case closed         // 流完全关闭
    case resetSent      // 发送了RESET_STREAM
    case resetReceived  // 接收了RESET_STREAM
    
    public var debugDescription: String {
        switch self {
        case .idle: return "idle"
        case .open: return "open"
        case .halfClosed: return "halfClosed"
        case .closed: return "closed"
        case .resetSent: return "resetSent"
        case .resetReceived: return "resetReceived"
        }
    }
}

// MARK: - 流事件
public enum StreamEvent {
    case created
    case sentFin
    case receivedFin
    case reset
    case dataReceived
    case dataSent
}

// MARK: - 流优先级
public struct StreamPriority: Equatable {
    public let urgency: UInt8      // 0-7, 7为最高优先级
    public let incremental: Bool   // 是否为增量传输
    
    public init(urgency: UInt8 = 3, incremental: Bool = false) {
        self.urgency = min(urgency, 7)
        self.incremental = incremental
    }
    
    public static let `default` = StreamPriority()
    public static let high = StreamPriority(urgency: 7)
    public static let low = StreamPriority(urgency: 0)
}

// MARK: - 调度策略
public enum SchedulingPolicy {
    case fifo           // 先进先出
    case priority       // 基于优先级
    case fairShare      // 公平共享
    case weighted       // 加权调度
}

// MARK: - 流错误
public enum StreamError: Error, LocalizedError {
    case streamNotWritable
    case streamNotReadable
    case invalidStreamState
    case invalidOffset
    case flowControlBlocked
    case streamAlreadyClosed
    case streamNotFound
    case invalidStreamID
    case bufferOverflow
    case frameTooLarge
    
    public var errorDescription: String? {
        switch self {
        case .streamNotWritable:
            return "Stream is not writable"
        case .streamNotReadable:
            return "Stream is not readable"
        case .invalidStreamState:
            return "Invalid stream state for operation"
        case .invalidOffset:
            return "Invalid data offset"
        case .flowControlBlocked:
            return "Flow control blocked"
        case .streamAlreadyClosed:
            return "Stream is already closed"
        case .streamNotFound:
            return "Stream not found"
        case .invalidStreamID:
            return "Invalid stream ID"
        case .bufferOverflow:
            return "Buffer overflow"
        case .frameTooLarge:
            return "Frame too large"
        }
    }
}

// MARK: - 流调试信息
public struct StreamDebugInfo {
    public let id: UInt64
    public let state: StreamState
    public let sendBufferSize: Int
    public let receiveBufferSize: Int
    public let flowControlWindow: UInt64
    public let bytesReceived: UInt64
    public let bytesSent: UInt64
    public let createdAt: Date
    
    public var debugDescription: String {
        return """
        Stream \(id) (\(state.debugDescription)):
          Send Buffer: \(sendBufferSize) bytes
          Receive Buffer: \(receiveBufferSize) bytes
          Flow Window: \(flowControlWindow) bytes
          Bytes Sent: \(bytesSent)
          Bytes Received: \(bytesReceived)
          Created: \(createdAt)
        """
    }
}

// MARK: - 流统计信息
public struct StreamStatistics {
    public let activeStreams: Int
    public let totalStreamsCreated: UInt64
    public let totalBytesSent: UInt64
    public let totalBytesReceived: UInt64
    public let averageStreamLifetime: TimeInterval
    public let flowControlBlocks: UInt64
    
    public var debugDescription: String {
        return """
        Stream Statistics:
          Active Streams: \(activeStreams)
          Total Created: \(totalStreamsCreated)
          Bytes Sent: \(totalBytesSent)
          Bytes Received: \(totalBytesReceived)
          Avg Lifetime: \(String(format: "%.2f", averageStreamLifetime))s
          Flow Blocks: \(flowControlBlocks)
        """
    }
}