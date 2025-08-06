import Foundation

// MARK: - 流调度器
public class StreamScheduler {
    private var streamQueue: [ScheduledStream] = []
    private var streamPriorities: [UInt64: StreamPriority] = [:]
    private var schedulingPolicy: SchedulingPolicy = .priority
    private var roundRobinIndex = 0
    private let lock = NSLock()
    
    // 调度统计
    private var totalScheduled: UInt64 = 0
    private var schedulesByPriority: [UInt8: UInt64] = [:]
    private var lastScheduleTime: Date?
    
    // 回调
    public var onStreamScheduled: ((UInt64, Int) -> Void)?
    public var onSchedulingPolicyChanged: ((SchedulingPolicy) -> Void)?
    
    public init(policy: SchedulingPolicy = .priority) {
        self.schedulingPolicy = policy
    }
    
    // MARK: - 流管理
    public func addStream(_ stream: QUICStream, priority: StreamPriority = .default) {
        lock.withLock {
            let scheduledStream = ScheduledStream(
                stream: stream,
                priority: priority,
                lastScheduled: nil,
                bytesScheduled: 0
            )
            
            streamQueue.append(scheduledStream)
            streamPriorities[stream.id] = priority
            
            // 根据策略重新排序
            sortStreams()
        }
    }
    
    public func removeStream(id: UInt64) {
        lock.withLock {
            streamQueue.removeAll { $0.stream.id == id }
            streamPriorities.removeValue(forKey: id)
        }
    }
    
    public func updatePriority(streamID: UInt64, priority: StreamPriority) {
        lock.withLock {
            streamPriorities[streamID] = priority
            
            // 更新队列中的优先级
            for i in 0..<streamQueue.count {
                if streamQueue[i].stream.id == streamID {
                    streamQueue[i].priority = priority
                    break
                }
            }
            
            // 重新排序
            sortStreams()
        }
    }
    
    public func setSchedulingPolicy(_ policy: SchedulingPolicy) {
        lock.withLock {
            schedulingPolicy = policy
            sortStreams()
            onSchedulingPolicyChanged?(policy)
        }
    }
    
    // MARK: - 核心调度逻辑
    public func scheduleStreams(maxTotalBytes: Int = Int.max) -> [StreamScheduleResult] {
        return lock.withLock {
            var results: [StreamScheduleResult] = []
            let remainingBytes = maxTotalBytes
            
            switch schedulingPolicy {
            case .fifo:
                results = scheduleFIFO(maxBytes: remainingBytes)
            case .priority:
                results = schedulePriority(maxBytes: remainingBytes)
            case .fairShare:
                results = scheduleFairShare(maxBytes: remainingBytes)
            case .weighted:
                results = scheduleWeighted(maxBytes: remainingBytes)
            }
            
            // 更新统计信息
            updateSchedulingStatistics(results)
            lastScheduleTime = Date()
            
            return results
        }
    }
    
    // MARK: - FIFO调度
    private func scheduleFIFO(maxBytes: Int) -> [StreamScheduleResult] {
        var results: [StreamScheduleResult] = []
        var remainingBytes = maxBytes
        
        for scheduledStream in streamQueue {
            guard remainingBytes > 0 else { break }
            
            if scheduledStream.stream.hasDataToSend {
                let bytesForStream = min(remainingBytes, 1500) // MTU限制
                results.append(StreamScheduleResult(
                    streamID: scheduledStream.stream.id,
                    priority: scheduledStream.priority,
                    bytesAllocated: bytesForStream
                ))
                remainingBytes -= bytesForStream
            }
        }
        
        return results
    }
    
    // MARK: - 优先级调度
    private func schedulePriority(maxBytes: Int) -> [StreamScheduleResult] {
        var results: [StreamScheduleResult] = []
        var remainingBytes = maxBytes
        
        // 按优先级分组
        let groupedStreams = Dictionary(grouping: streamQueue) { $0.priority.urgency }
        let sortedPriorities = groupedStreams.keys.sorted(by: >) // 高优先级优先
        
        for urgency in sortedPriorities {
            guard remainingBytes > 0 else { break }
            guard let streams = groupedStreams[urgency] else { continue }
            
            // 在同优先级内按照增量标志排序
            let sortedStreams = streams.sorted { stream1, stream2 in
                if stream1.priority.incremental != stream2.priority.incremental {
                    return !stream1.priority.incremental // 非增量优先
                }
                return stream1.stream.id < stream2.stream.id // 稳定排序
            }
            
            for scheduledStream in sortedStreams {
                guard remainingBytes > 0 else { break }
                
                if scheduledStream.stream.hasDataToSend {
                    let bytesForStream = calculateBytesForStream(
                        scheduledStream,
                        maxBytes: remainingBytes,
                        policy: .priority
                    )
                    
                    if bytesForStream > 0 {
                        results.append(StreamScheduleResult(
                            streamID: scheduledStream.stream.id,
                            priority: scheduledStream.priority,
                            bytesAllocated: bytesForStream
                        ))
                        remainingBytes -= bytesForStream
                    }
                }
            }
        }
        
        return results
    }
    
    // MARK: - 公平共享调度
    private func scheduleFairShare(maxBytes: Int) -> [StreamScheduleResult] {
        var results: [StreamScheduleResult] = []
        let activeStreams = streamQueue.filter { $0.stream.hasDataToSend }
        
        guard !activeStreams.isEmpty else { return results }
        
        let bytesPerStream = max(1, maxBytes / activeStreams.count)
        var remainingBytes = maxBytes
        
        // 多轮调度确保公平性
        var round = 0
        let maxRounds = 10
        
        while remainingBytes > 0 && round < maxRounds {
            var scheduledInRound = false
            
            for scheduledStream in activeStreams {
                guard remainingBytes > 0 else { break }
                
                if scheduledStream.stream.hasDataToSend {
                    let bytesForStream = min(remainingBytes, bytesPerStream)
                    
                    if let existingResult = results.first(where: { $0.streamID == scheduledStream.stream.id }) {
                        // 更新现有结果
                        let index = results.firstIndex { $0.streamID == scheduledStream.stream.id }!
                        results[index] = StreamScheduleResult(
                            streamID: scheduledStream.stream.id,
                            priority: scheduledStream.priority,
                            bytesAllocated: existingResult.bytesAllocated + bytesForStream
                        )
                    } else {
                        // 添加新结果
                        results.append(StreamScheduleResult(
                            streamID: scheduledStream.stream.id,
                            priority: scheduledStream.priority,
                            bytesAllocated: bytesForStream
                        ))
                    }
                    
                    remainingBytes -= bytesForStream
                    scheduledInRound = true
                }
            }
            
            if !scheduledInRound {
                break
            }
            
            round += 1
        }
        
        return results
    }
    
    // MARK: - 加权调度
    private func scheduleWeighted(maxBytes: Int) -> [StreamScheduleResult] {
        var results: [StreamScheduleResult] = []
        let activeStreams = streamQueue.filter { $0.stream.hasDataToSend }
        
        guard !activeStreams.isEmpty else { return results }
        
        // 计算权重总和
        let totalWeight = activeStreams.reduce(0) { total, scheduledStream in
            total + calculateWeight(for: scheduledStream.priority)
        }
        
        var remainingBytes = maxBytes
        
        for scheduledStream in activeStreams {
            guard remainingBytes > 0 else { break }
            
            let weight = calculateWeight(for: scheduledStream.priority)
            let bytesForStream = Int(Double(maxBytes) * Double(weight) / Double(totalWeight))
            let actualBytes = min(remainingBytes, bytesForStream)
            
            if actualBytes > 0 {
                results.append(StreamScheduleResult(
                    streamID: scheduledStream.stream.id,
                    priority: scheduledStream.priority,
                    bytesAllocated: actualBytes
                ))
                remainingBytes -= actualBytes
            }
        }
        
        return results
    }
    
    // MARK: - 辅助方法
    private func sortStreams() {
        switch schedulingPolicy {
        case .fifo:
            // FIFO不需要特殊排序，保持添加顺序
            break
        case .priority:
            streamQueue.sort { stream1, stream2 in
                if stream1.priority.urgency != stream2.priority.urgency {
                    return stream1.priority.urgency > stream2.priority.urgency
                }
                if stream1.priority.incremental != stream2.priority.incremental {
                    return !stream1.priority.incremental
                }
                return stream1.stream.id < stream2.stream.id
            }
        case .fairShare:
            // 公平共享使用轮询，不需要特殊排序
            break
        case .weighted:
            streamQueue.sort { stream1, stream2 in
                let weight1 = calculateWeight(for: stream1.priority)
                let weight2 = calculateWeight(for: stream2.priority)
                if weight1 != weight2 {
                    return weight1 > weight2
                }
                return stream1.stream.id < stream2.stream.id
            }
        }
    }
    
    private func calculateBytesForStream(_ scheduledStream: ScheduledStream, maxBytes: Int, policy: SchedulingPolicy) -> Int {
        switch policy {
        case .priority:
            // 高优先级流可以获得更多字节
            let multiplier = Double(scheduledStream.priority.urgency + 1) / 8.0
            return min(maxBytes, Int(1500.0 * multiplier))
        case .fairShare:
            return min(maxBytes, 1500)
        case .weighted:
            let weight = calculateWeight(for: scheduledStream.priority)
            return min(maxBytes, Int(1500.0 * Double(weight) / 8.0))
        case .fifo:
            return min(maxBytes, 1500)
        }
    }
    
    private func calculateWeight(for priority: StreamPriority) -> UInt32 {
        var weight = UInt32(priority.urgency + 1)
        if priority.incremental {
            weight = weight / 2 // 增量传输权重减半
        }
        return max(1, weight)
    }
    
    private func updateSchedulingStatistics(_ results: [StreamScheduleResult]) {
        totalScheduled += UInt64(results.count)
        
        for result in results {
            let urgency = result.priority.urgency
            schedulesByPriority[urgency] = (schedulesByPriority[urgency] ?? 0) + 1
            
            // 更新流的调度信息
            for i in 0..<streamQueue.count {
                if streamQueue[i].stream.id == result.streamID {
                    streamQueue[i].lastScheduled = Date()
                    streamQueue[i].bytesScheduled += UInt64(result.bytesAllocated)
                    break
                }
            }
            
            onStreamScheduled?(result.streamID, result.bytesAllocated)
        }
    }
    
    // MARK: - 查询方法
    public func getActiveStreams() -> [QUICStream] {
        return lock.withLock {
            return streamQueue.map { $0.stream }
        }
    }
    
    public func getStreamPriority(_ streamID: UInt64) -> StreamPriority? {
        return lock.withLock {
            return streamPriorities[streamID]
        }
    }
    
    public func getSchedulingStatistics() -> SchedulingStatistics {
        return lock.withLock {
            let activeCount = streamQueue.filter { $0.stream.hasDataToSend }.count
            
            return SchedulingStatistics(
                policy: schedulingPolicy,
                totalStreams: streamQueue.count,
                activeStreams: activeCount,
                totalScheduled: totalScheduled,
                schedulesByPriority: schedulesByPriority,
                lastScheduleTime: lastScheduleTime
            )
        }
    }
    
    // MARK: - 维护
    public func performMaintenance() {
        lock.withLock {
            // 清理已关闭的流
            streamQueue.removeAll { scheduledStream in
                scheduledStream.stream.isClosed
            }
            
            // 清理优先级映射
            let activeStreamIDs = Set(streamQueue.map { $0.stream.id })
            streamPriorities = streamPriorities.filter { activeStreamIDs.contains($0.key) }
        }
    }
    
    public func debugInfo() -> String {
        let stats = getSchedulingStatistics()
        
        return """
        StreamScheduler Info:
          Policy: \(stats.policy)
          Total Streams: \(stats.totalStreams)
          Active Streams: \(stats.activeStreams)
          Total Scheduled: \(stats.totalScheduled)
          Last Schedule: \(stats.lastScheduleTime?.timeIntervalSinceNow.description ?? "never")
          
          By Priority:
        \(stats.schedulesByPriority.map { "    Priority \($0.key): \($0.value)" }.joined(separator: "\n"))
        """
    }
}

// MARK: - 调度相关数据结构
private struct ScheduledStream {
    let stream: QUICStream
    var priority: StreamPriority
    var lastScheduled: Date?
    var bytesScheduled: UInt64
}

public struct StreamScheduleResult {
    public let streamID: UInt64
    public let priority: StreamPriority
    public let bytesAllocated: Int
    
    public var debugDescription: String {
        return "Schedule(id=\(streamID), urgency=\(priority.urgency), bytes=\(bytesAllocated))"
    }
}

public struct SchedulingStatistics {
    public let policy: SchedulingPolicy
    public let totalStreams: Int
    public let activeStreams: Int
    public let totalScheduled: UInt64
    public let schedulesByPriority: [UInt8: UInt64]
    public let lastScheduleTime: Date?
    
    public var debugDescription: String {
        return """
        SchedulingStats:
          Policy: \(policy)
          Streams: \(activeStreams)/\(totalStreams)
          Total Scheduled: \(totalScheduled)
          Last: \(lastScheduleTime?.description ?? "never")
        """
    }
}

// MARK: - 高级调度器
public class AdvancedStreamScheduler: StreamScheduler {
    private var bandwidthEstimate: UInt64 = 1000000 // 1Mbps初始估计
    private var congestionWindow: UInt64 = 10000
    private var adaptiveScheduling = true
    
    public override init(policy: SchedulingPolicy = .priority) {
        super.init(policy: policy)
    }
    
    public func updateBandwidthEstimate(_ estimate: UInt64) {
        bandwidthEstimate = estimate
    }
    
    public func updateCongestionWindow(_ window: UInt64) {
        congestionWindow = window
    }
    
    public override func scheduleStreams(maxTotalBytes: Int = Int.max) -> [StreamScheduleResult] {
        let effectiveMaxBytes = adaptiveScheduling ? 
            min(maxTotalBytes, Int(congestionWindow)) : 
            maxTotalBytes
        
        return super.scheduleStreams(maxTotalBytes: effectiveMaxBytes)
    }
    
    public func enableAdaptiveScheduling(_ enabled: Bool) {
        adaptiveScheduling = enabled
    }
}