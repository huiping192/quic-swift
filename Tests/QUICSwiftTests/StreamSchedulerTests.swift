import XCTest
@testable import QUICSwift

final class StreamSchedulerTests: XCTestCase {
    var scheduler: StreamScheduler!
    var mockStreams: [QUICStream] = []
    
    override func setUp() {
        super.setUp()
        scheduler = StreamScheduler(policy: .priority)
        
        // 创建一些模拟流
        mockStreams = [
            QUICStream(id: 0, type: .bidirectional, initialWindowSize: 65536),
            QUICStream(id: 4, type: .bidirectional, initialWindowSize: 65536),
            QUICStream(id: 8, type: .unidirectional, initialWindowSize: 65536),
            QUICStream(id: 12, type: .unidirectional, initialWindowSize: 65536)
        ]
        
        // 为流添加一些测试数据
        for stream in mockStreams {
            let testData = "Test data for stream \(stream.id)".data(using: .utf8)!
            try! stream.writeWithoutBlocking(data: testData)
        }
    }
    
    override func tearDown() {
        mockStreams = []
        scheduler = nil
        super.tearDown()
    }
    
    func testInitialState() {
        XCTAssertEqual(scheduler.getActiveStreams().count, 0)
        
        let stats = scheduler.getSchedulingStatistics()
        XCTAssertEqual(stats.totalStreams, 0)
        XCTAssertEqual(stats.activeStreams, 0)
        XCTAssertEqual(stats.totalScheduled, 0)
    }
    
    func testAddAndRemoveStreams() {
        let stream = mockStreams[0]
        let priority = StreamPriority(urgency: 5, incremental: false)
        
        // 添加流
        scheduler.addStream(stream, priority: priority)
        XCTAssertEqual(scheduler.getActiveStreams().count, 1)
        XCTAssertEqual(scheduler.getStreamPriority(stream.id), priority)
        
        // 移除流
        scheduler.removeStream(id: stream.id)
        XCTAssertEqual(scheduler.getActiveStreams().count, 0)
        XCTAssertNil(scheduler.getStreamPriority(stream.id))
    }
    
    func testPriorityScheduling() {
        // 添加不同优先级的流
        scheduler.addStream(mockStreams[0], priority: StreamPriority(urgency: 3)) // 中等优先级
        scheduler.addStream(mockStreams[1], priority: StreamPriority(urgency: 7)) // 高优先级
        scheduler.addStream(mockStreams[2], priority: StreamPriority(urgency: 1)) // 低优先级
        
        scheduler.setSchedulingPolicy(.priority)
        
        let results = scheduler.scheduleStreams(maxTotalBytes: 1000)
        
        XCTAssertGreaterThan(results.count, 0)
        
        // 验证高优先级流被首先调度
        if results.count > 1 {
            XCTAssertGreaterThanOrEqual(results[0].priority.urgency, results[1].priority.urgency)
        }
    }
    
    func testFIFOScheduling() {
        // 按顺序添加流
        for (index, stream) in mockStreams.enumerated() {
            scheduler.addStream(stream, priority: StreamPriority(urgency: UInt8(index)))
        }
        
        scheduler.setSchedulingPolicy(.fifo)
        
        let results = scheduler.scheduleStreams(maxTotalBytes: 2000)
        
        XCTAssertGreaterThan(results.count, 0)
        
        // FIFO应该按添加顺序调度
        if results.count > 1 {
            XCTAssertLessThan(results[0].streamID, results[1].streamID)
        }
    }
    
    func testFairShareScheduling() {
        // 添加多个流
        for stream in mockStreams {
            scheduler.addStream(stream, priority: .default)
        }
        
        scheduler.setSchedulingPolicy(.fairShare)
        
        let results = scheduler.scheduleStreams(maxTotalBytes: 4000)
        
        // 公平共享应该为每个活跃流分配大致相等的字节数
        XCTAssertGreaterThan(results.count, 0)
        
        if results.count > 1 {
            let bytesAllocated = results.map { $0.bytesAllocated }
            let maxBytes = bytesAllocated.max()!
            let minBytes = bytesAllocated.min()!
            
            // 分配的字节数应该相对均匀
            XCTAssertLessThanOrEqual(maxBytes - minBytes, maxBytes / 2)
        }
    }
    
    func testWeightedScheduling() {
        // 添加不同权重的流
        scheduler.addStream(mockStreams[0], priority: StreamPriority(urgency: 7)) // 高权重
        scheduler.addStream(mockStreams[1], priority: StreamPriority(urgency: 3)) // 中等权重
        scheduler.addStream(mockStreams[2], priority: StreamPriority(urgency: 1)) // 低权重
        
        scheduler.setSchedulingPolicy(.weighted)
        
        let results = scheduler.scheduleStreams(maxTotalBytes: 3000)
        
        XCTAssertGreaterThan(results.count, 0)
        
        // 高权重流应该获得更多字节
        if results.count >= 2 {
            let highPriorityResult = results.first { $0.priority.urgency == 7 }
            let lowPriorityResult = results.first { $0.priority.urgency == 1 }
            
            if let high = highPriorityResult, let low = lowPriorityResult {
                XCTAssertGreaterThan(high.bytesAllocated, low.bytesAllocated)
            }
        }
    }
    
    func testUpdatePriority() {
        let stream = mockStreams[0]
        let initialPriority = StreamPriority(urgency: 3)
        let updatedPriority = StreamPriority(urgency: 7)
        
        scheduler.addStream(stream, priority: initialPriority)
        XCTAssertEqual(scheduler.getStreamPriority(stream.id)?.urgency, 3)
        
        scheduler.updatePriority(streamID: stream.id, priority: updatedPriority)
        XCTAssertEqual(scheduler.getStreamPriority(stream.id)?.urgency, 7)
    }
    
    func testSchedulingWithByteLimits() {
        // 添加多个流
        for stream in mockStreams {
            scheduler.addStream(stream, priority: .default)
        }
        
        let maxBytes = 500
        let results = scheduler.scheduleStreams(maxTotalBytes: maxBytes)
        
        let totalScheduled = results.reduce(0) { $0 + $1.bytesAllocated }
        XCTAssertLessThanOrEqual(totalScheduled, maxBytes)
    }
    
    func testIncrementalPriority() {
        let nonIncremental = StreamPriority(urgency: 5, incremental: false)
        let incremental = StreamPriority(urgency: 5, incremental: true)
        
        scheduler.addStream(mockStreams[0], priority: nonIncremental)
        scheduler.addStream(mockStreams[1], priority: incremental)
        
        scheduler.setSchedulingPolicy(.priority)
        
        let results = scheduler.scheduleStreams(maxTotalBytes: 1000)
        
        // 非增量流应该有更高的优先级
        if results.count >= 2 {
            let nonIncrementalResult = results.first { !$0.priority.incremental }
            let incrementalResult = results.first { $0.priority.incremental }
            
            if let nonInc = nonIncrementalResult, let inc = incrementalResult {
                let nonIncIndex = results.firstIndex { $0.streamID == nonInc.streamID }!
                let incIndex = results.firstIndex { $0.streamID == inc.streamID }!
                XCTAssertLessThan(nonIncIndex, incIndex)
            }
        }
    }
    
    func testSchedulingStatistics() {
        // 添加流并进行调度
        for stream in mockStreams {
            scheduler.addStream(stream, priority: .default)
        }
        
        let _ = scheduler.scheduleStreams(maxTotalBytes: 2000)
        
        let stats = scheduler.getSchedulingStatistics()
        
        XCTAssertEqual(stats.totalStreams, mockStreams.count)
        XCTAssertGreaterThan(stats.totalScheduled, 0)
        XCTAssertNotNil(stats.lastScheduleTime)
        XCTAssertFalse(stats.schedulesByPriority.isEmpty)
    }
    
    func testPerformMaintenance() {
        // 添加流
        for stream in mockStreams {
            scheduler.addStream(stream, priority: .default)
        }
        
        let initialCount = scheduler.getActiveStreams().count
        
        // 执行维护
        scheduler.performMaintenance()
        
        // 由于流还是活跃的，数量应该保持不变
        XCTAssertEqual(scheduler.getActiveStreams().count, initialCount)
    }
    
    func testCallbacks() {
        var streamScheduledCalled = false
        var policyChangedCalled = false
        var scheduledStreamID: UInt64?
        var scheduledBytes: Int?
        
        scheduler.onStreamScheduled = { streamID, bytes in
            streamScheduledCalled = true
            scheduledStreamID = streamID
            scheduledBytes = bytes
        }
        
        scheduler.onSchedulingPolicyChanged = { policy in
            policyChangedCalled = true
        }
        
        // 添加流并调度
        scheduler.addStream(mockStreams[0], priority: .default)
        let results = scheduler.scheduleStreams(maxTotalBytes: 1000)
        
        if !results.isEmpty {
            XCTAssertTrue(streamScheduledCalled)
            XCTAssertNotNil(scheduledStreamID)
            XCTAssertNotNil(scheduledBytes)
        }
        
        // 改变策略
        scheduler.setSchedulingPolicy(.fairShare)
        XCTAssertTrue(policyChangedCalled)
    }
    
    func testDebugInfo() {
        // 添加一些流
        for stream in mockStreams.prefix(2) {
            scheduler.addStream(stream, priority: .default)
        }
        
        let debugInfo = scheduler.debugInfo()
        
        XCTAssertTrue(debugInfo.contains("StreamScheduler Info"))
        XCTAssertTrue(debugInfo.contains("Policy:"))
        XCTAssertTrue(debugInfo.contains("Total Streams:"))
        XCTAssertTrue(debugInfo.contains("Active Streams:"))
    }
    
    func testAdvancedScheduler() {
        let advancedScheduler = AdvancedStreamScheduler(policy: .priority)
        
        // 添加流
        for stream in mockStreams {
            advancedScheduler.addStream(stream, priority: .default)
        }
        
        // 更新带宽估计和拥塞窗口
        advancedScheduler.updateBandwidthEstimate(2000000) // 2Mbps
        advancedScheduler.updateCongestionWindow(5000)
        
        let results = advancedScheduler.scheduleStreams(maxTotalBytes: 10000)
        
        // 自适应调度可能会限制总字节数
        let totalBytes = results.reduce(0) { $0 + $1.bytesAllocated }
        XCTAssertLessThanOrEqual(totalBytes, 10000)
    }
    
    func testEmptyScheduling() {
        // 没有流的情况下调度
        let results = scheduler.scheduleStreams(maxTotalBytes: 1000)
        XCTAssertEqual(results.count, 0)
    }
    
    func testSchedulingWithNoData() {
        // 添加没有数据要发送的流
        let emptyStream = QUICStream(id: 100, type: .bidirectional)
        scheduler.addStream(emptyStream, priority: .default)
        
        let results = scheduler.scheduleStreams(maxTotalBytes: 1000)
        XCTAssertEqual(results.count, 0)
    }
    
    func testMultipleSchedulingRounds() {
        // 添加流
        for stream in mockStreams {
            scheduler.addStream(stream, priority: .default)
        }
        
        // 进行多轮调度
        for _ in 0..<5 {
            let results = scheduler.scheduleStreams(maxTotalBytes: 500)
            XCTAssertGreaterThanOrEqual(results.count, 0)
        }
        
        let stats = scheduler.getSchedulingStatistics()
        XCTAssertGreaterThan(stats.totalScheduled, 0)
    }
    
    func testScheduleResultDescription() {
        let result = StreamScheduleResult(
            streamID: 42,
            priority: StreamPriority(urgency: 5),
            bytesAllocated: 1500
        )
        
        let description = result.debugDescription
        XCTAssertTrue(description.contains("42"))
        XCTAssertTrue(description.contains("5"))
        XCTAssertTrue(description.contains("1500"))
    }
}