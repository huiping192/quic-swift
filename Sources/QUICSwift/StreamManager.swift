import Foundation

// MARK: - 流管理器
public class StreamManager {
    private var streams: [UInt64: QUICStream] = [:]
    private var nextClientBidirectionalStreamID: UInt64 = 0  // 0, 4, 8, ...
    private var nextClientUnidirectionalStreamID: UInt64 = 2 // 2, 6, 10, ...
    private var nextServerBidirectionalStreamID: UInt64 = 1  // 1, 5, 9, ...
    private var nextServerUnidirectionalStreamID: UInt64 = 3 // 3, 7, 11, ...
    
    // 流限制
    private var maxBidirectionalStreams: UInt64 = 1000
    private var maxUnidirectionalStreams: UInt64 = 1000
    private var initialStreamWindowSize: UInt64 = 65536
    
    // 统计信息
    private var totalStreamsCreated: UInt64 = 0
    private var streamCreationTimes: [UInt64: Date] = [:]
    
    private let lock = NSLock()
    private let role: QUICConnectionRole
    
    // 回调
    public var onStreamCreated: ((QUICStream) -> Void)?
    public var onStreamClosed: ((UInt64, StreamState) -> Void)?
    public var onStreamLimitReached: ((StreamType) -> Void)?
    
    public init(role: QUICConnectionRole, 
                maxBidirectionalStreams: UInt64 = 1000, 
                maxUnidirectionalStreams: UInt64 = 1000,
                initialStreamWindowSize: UInt64 = 65536) {
        self.role = role
        self.maxBidirectionalStreams = maxBidirectionalStreams
        self.maxUnidirectionalStreams = maxUnidirectionalStreams
        self.initialStreamWindowSize = initialStreamWindowSize
    }
    
    // MARK: - 流创建
    public func createStream(type: StreamType, initiator: StreamInitiator) throws -> QUICStream {
        return try lock.withLock {
            // 检查流限制
            let currentCount = getStreamCount(type: type, initiator: initiator)
            let maxCount = type == .bidirectional ? maxBidirectionalStreams : maxUnidirectionalStreams
            
            guard currentCount < maxCount else {
                onStreamLimitReached?(type)
                throw StreamError.streamNotFound // 应该有专门的流限制错误
            }
            
            let streamID = generateStreamID(type: type, initiator: initiator)
            let stream = QUICStream(id: streamID, type: type, initialWindowSize: initialStreamWindowSize)
            
            // 设置流的回调
            setupStreamCallbacks(stream)
            
            streams[streamID] = stream
            streamCreationTimes[streamID] = Date()
            totalStreamsCreated += 1
            
            onStreamCreated?(stream)
            
            return stream
        }
    }
    
    public func createStreamWithID(_ streamID: UInt64) throws -> QUICStream {
        return try lock.withLock {
            guard streams[streamID] == nil else {
                throw StreamError.invalidStreamID
            }
            
            guard isValidPeerStreamID(streamID) else {
                throw StreamError.invalidStreamID
            }
            
            let type = StreamType.fromStreamID(streamID)
            let stream = QUICStream(id: streamID, type: type, initialWindowSize: initialStreamWindowSize)
            
            setupStreamCallbacks(stream)
            
            streams[streamID] = stream
            streamCreationTimes[streamID] = Date()
            totalStreamsCreated += 1
            
            onStreamCreated?(stream)
            
            return stream
        }
    }
    
    // MARK: - 流查找和管理
    public func getStream(id: UInt64) -> QUICStream? {
        return lock.withLock {
            return streams[id]
        }
    }
    
    public func getAllActiveStreams() -> [QUICStream] {
        return lock.withLock {
            return streams.values.filter { $0.isActive }
        }
    }
    
    public func getStreams(type: StreamType) -> [QUICStream] {
        return lock.withLock {
            return streams.values.filter { $0.type == type }
        }
    }
    
    public func getStreams(initiator: StreamInitiator) -> [QUICStream] {
        return lock.withLock {
            return streams.values.filter { $0.initiator == initiator }
        }
    }
    
    // MARK: - 流路由
    public func routeStreamFrame(_ frame: StreamFrame) -> QUICStream? {
        return lock.withLock {
            // 如果流不存在，尝试创建（peer-initiated）
            if streams[frame.streamID] == nil {
                do {
                    let stream = try createStreamWithID(frame.streamID)
                    return stream
                } catch {
                    return nil
                }
            }
            return streams[frame.streamID]
        }
    }
    
    public func routeControlFrame(streamID: UInt64) -> QUICStream? {
        return lock.withLock {
            return streams[streamID]
        }
    }
    
    // MARK: - 流关闭和重置
    public func closeStream(id: UInt64) {
        lock.withLock {
            guard let stream = streams[id] else { return }
            
            Task {
                try? await stream.close()
            }
        }
    }
    
    public func resetStream(id: UInt64, errorCode: UInt64) {
        lock.withLock {
            guard let stream = streams[id] else { return }
            
            Task {
                try? await stream.reset(errorCode: errorCode)
            }
        }
    }
    
    public func removeStream(id: UInt64) {
        lock.withLock {
            if let stream = streams.removeValue(forKey: id) {
                streamCreationTimes.removeValue(forKey: id)
                onStreamClosed?(id, stream.state)
            }
        }
    }
    
    // MARK: - 流限制管理
    public func updateMaxStreams(bidirectional: UInt64? = nil, unidirectional: UInt64? = nil) {
        lock.withLock {
            if let bidi = bidirectional {
                maxBidirectionalStreams = bidi
            }
            if let uni = unidirectional {
                maxUnidirectionalStreams = uni
            }
        }
    }
    
    public func canCreateStream(type: StreamType, initiator: StreamInitiator) -> Bool {
        return lock.withLock {
            let currentCount = getStreamCount(type: type, initiator: initiator)
            let maxCount = type == .bidirectional ? maxBidirectionalStreams : maxUnidirectionalStreams
            return currentCount < maxCount
        }
    }
    
    // MARK: - 流数据处理
    public func processStreamFrames(_ frames: [StreamFrame]) async {
        for frame in frames {
            if let stream = routeStreamFrame(frame) {
                do {
                    try await stream.handleStreamFrame(frame)
                } catch {
                    // 处理流帧错误
                    resetStream(id: frame.streamID, errorCode: 0x01) // APPLICATION_ERROR
                }
            }
        }
    }
    
    public func getDataToSend(maxTotalBytes: Int) -> [StreamFrame] {
        let activeStreams = getAllActiveStreams()
        var frames: [StreamFrame] = []
        var remainingBytes = maxTotalBytes
        
        // 简单的轮询调度
        for stream in activeStreams {
            if remainingBytes <= 0 { break }
            
            if let frame = stream.getDataToSend(maxBytes: remainingBytes) {
                frames.append(frame)
                remainingBytes -= frame.data.count
                
                // 标记数据已发送
                stream.markDataSent(bytes: frame.data.count)
            }
        }
        
        return frames
    }
    
    // MARK: - 内部方法
    private func setupStreamCallbacks(_ stream: QUICStream) {
        stream.onStateChange = { [weak self] oldState, newState in
            if newState == .closed || newState == .resetSent || newState == .resetReceived {
                self?.removeStream(id: stream.id)
            }
        }
    }
    
    private func generateStreamID(type: StreamType, initiator: StreamInitiator) -> UInt64 {
        switch (initiator, type) {
        case (.client, .bidirectional):
            let id = nextClientBidirectionalStreamID
            nextClientBidirectionalStreamID += 4
            return id
        case (.client, .unidirectional):
            let id = nextClientUnidirectionalStreamID
            nextClientUnidirectionalStreamID += 4
            return id
        case (.server, .bidirectional):
            let id = nextServerBidirectionalStreamID
            nextServerBidirectionalStreamID += 4
            return id
        case (.server, .unidirectional):
            let id = nextServerUnidirectionalStreamID
            nextServerUnidirectionalStreamID += 4
            return id
        }
    }
    
    private func isValidPeerStreamID(_ streamID: UInt64) -> Bool {
        let initiator = StreamInitiator.fromStreamID(streamID)
        let type = StreamType.fromStreamID(streamID)
        
        // 检查是否为对端发起的流
        let isPeerInitiated = (role == .client && initiator == .server) ||
                             (role == .server && initiator == .client)
        
        guard isPeerInitiated else { return false }
        
        // 检查流限制
        let currentCount = getStreamCount(type: type, initiator: initiator)
        let maxCount = type == .bidirectional ? maxBidirectionalStreams : maxUnidirectionalStreams
        
        return currentCount < maxCount
    }
    
    private func getStreamCount(type: StreamType, initiator: StreamInitiator) -> UInt64 {
        let count = streams.values.filter { stream in
            stream.type == type && stream.initiator == initiator
        }.count
        return UInt64(count)
    }
    
    // MARK: - 清理和维护
    public func performMaintenance() {
        lock.withLock {
            let now = Date()
            var streamsToRemove: [UInt64] = []
            
            for (streamID, stream) in streams {
                // 清理已关闭的流
                if stream.isClosed {
                    streamsToRemove.append(streamID)
                }
                
                // 清理长时间不活跃的流（可选）
                if let creationTime = streamCreationTimes[streamID],
                   now.timeIntervalSince(creationTime) > 3600 && !stream.isActive {
                    streamsToRemove.append(streamID)
                }
            }
            
            for streamID in streamsToRemove {
                streams.removeValue(forKey: streamID)
                streamCreationTimes.removeValue(forKey: streamID)
            }
        }
    }
    
    // MARK: - 统计信息
    public func getStatistics() -> StreamStatistics {
        return lock.withLock {
            let activeCount = streams.values.filter { $0.isActive }.count
            let totalBytes = streams.values.reduce((sent: UInt64(0), received: UInt64(0))) { result, stream in
                let info = stream.debugInfo
                return (result.sent + info.bytesSent, result.received + info.bytesReceived)
            }
            
            let lifetimes = streamCreationTimes.compactMap { (streamID, creationTime) -> TimeInterval? in
                guard let stream = streams[streamID], stream.isClosed else { return nil }
                return Date().timeIntervalSince(creationTime)
            }
            
            let averageLifetime = lifetimes.isEmpty ? 0 : lifetimes.reduce(0, +) / Double(lifetimes.count)
            
            return StreamStatistics(
                activeStreams: activeCount,
                totalStreamsCreated: totalStreamsCreated,
                totalBytesSent: totalBytes.sent,
                totalBytesReceived: totalBytes.received,
                averageStreamLifetime: averageLifetime,
                flowControlBlocks: 0 // TODO: 实现流量控制阻塞统计
            )
        }
    }
    
    public func getStreamLimits() -> (bidirectional: UInt64, unidirectional: UInt64) {
        return lock.withLock {
            return (maxBidirectionalStreams, maxUnidirectionalStreams)
        }
    }
    
    public func debugInfo() -> String {
        return lock.withLock {
            let stats = getStatistics()
            let streamsByType = Dictionary(grouping: streams.values) { $0.type }
            let streamsByInitiator = Dictionary(grouping: streams.values) { $0.initiator }
            
            return """
            StreamManager Info:
              Role: \(role)
              Active Streams: \(stats.activeStreams)
              Total Created: \(stats.totalStreamsCreated)
              
              By Type:
                Bidirectional: \(streamsByType[.bidirectional]?.count ?? 0)
                Unidirectional: \(streamsByType[.unidirectional]?.count ?? 0)
              
              By Initiator:
                Client: \(streamsByInitiator[.client]?.count ?? 0)
                Server: \(streamsByInitiator[.server]?.count ?? 0)
              
              Limits:
                Max Bidirectional: \(maxBidirectionalStreams)
                Max Unidirectional: \(maxUnidirectionalStreams)
              
              Next Stream IDs:
                Client Bidi: \(nextClientBidirectionalStreamID)
                Client Uni: \(nextClientUnidirectionalStreamID)
                Server Bidi: \(nextServerBidirectionalStreamID)
                Server Uni: \(nextServerUnidirectionalStreamID)
            """
        }
    }
}

// MARK: - 连接角色
public enum QUICConnectionRole {
    case client
    case server
}