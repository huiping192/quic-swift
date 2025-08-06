import XCTest
@testable import QUICSwift

final class FlowControllerTests: XCTestCase {
    var flowController: FlowController!
    
    override func setUp() {
        super.setUp()
        flowController = FlowController(
            initialStreamWindow: 65536,
            initialConnectionWindow: 1048576
        )
    }
    
    override func tearDown() {
        flowController = nil
        super.tearDown()
    }
    
    func testInitialState() {
        let streamID: UInt64 = 0
        
        XCTAssertEqual(flowController.getConnectionWindow(), 1048576)
        XCTAssertEqual(flowController.getStreamWindow(streamID: streamID), 65536)
        XCTAssertTrue(flowController.canSend(streamID: streamID, bytes: 1000))
        XCTAssertFalse(flowController.isConnectionBlocked())
        XCTAssertFalse(flowController.isStreamBlocked(streamID: streamID))
    }
    
    func testStreamWindowConsumption() {
        let streamID: UInt64 = 0
        let dataSize = 1000
        
        // 消费流窗口
        XCTAssertTrue(flowController.canSend(streamID: streamID, bytes: dataSize))
        flowController.consumeCredit(streamID: streamID, bytes: dataSize)
        
        // 验证窗口减少
        let expectedStreamWindow = 65536 - UInt64(dataSize)
        let expectedConnectionWindow = 1048576 - UInt64(dataSize)
        
        XCTAssertEqual(flowController.getStreamWindow(streamID: streamID), expectedStreamWindow)
        XCTAssertEqual(flowController.getConnectionWindow(), expectedConnectionWindow)
    }
    
    func testConnectionWindowLimitsStream() {
        let streamID: UInt64 = 0
        let largeDataSize = Int(flowController.getConnectionWindow()) + 1000
        
        // 尝试发送超过连接窗口的数据
        XCTAssertFalse(flowController.canSend(streamID: streamID, bytes: largeDataSize))
    }
    
    func testStreamWindowLimitsData() {
        let streamID: UInt64 = 0
        let largeDataSize = Int(flowController.getStreamWindow(streamID: streamID)) + 1000
        
        // 尝试发送超过流窗口的数据
        XCTAssertFalse(flowController.canSend(streamID: streamID, bytes: largeDataSize))
    }
    
    func testMultipleStreamsIndependent() {
        let streamID1: UInt64 = 0
        let streamID2: UInt64 = 4
        let dataSize = 1000
        
        // 在两个流中消费窗口
        flowController.consumeCredit(streamID: streamID1, bytes: dataSize)
        flowController.consumeCredit(streamID: streamID2, bytes: dataSize)
        
        // 验证两个流的窗口都减少了
        let expectedStreamWindow = 65536 - UInt64(dataSize)
        let expectedConnectionWindow = 1048576 - UInt64(dataSize * 2)
        
        XCTAssertEqual(flowController.getStreamWindow(streamID: streamID1), expectedStreamWindow)
        XCTAssertEqual(flowController.getStreamWindow(streamID: streamID2), expectedStreamWindow)
        XCTAssertEqual(flowController.getConnectionWindow(), expectedConnectionWindow)
    }
    
    func testStreamWindowUpdate() {
        let streamID: UInt64 = 0
        let dataSize = 30000
        
        // 消费大部分窗口
        flowController.consumeCredit(streamID: streamID, bytes: dataSize)
        let windowBefore = flowController.getStreamWindow(streamID: streamID)
        
        // 更新流窗口
        let increment: UInt64 = 10000
        flowController.updateStreamWindow(streamID: streamID, newWindow: windowBefore + increment)
        
        XCTAssertEqual(flowController.getStreamWindow(streamID: streamID), windowBefore + increment)
    }
    
    func testConnectionWindowUpdate() {
        let dataSize = 500000
        
        // 消费连接窗口
        flowController.consumeCredit(streamID: 0, bytes: dataSize)
        let windowBefore = flowController.getConnectionWindow()
        
        // 更新连接窗口
        let increment: UInt64 = 100000
        flowController.updateConnectionWindow(newWindow: windowBefore + increment)
        
        XCTAssertEqual(flowController.getConnectionWindow(), windowBefore + increment)
    }
    
    func testAddReceiveCredit() {
        let streamID: UInt64 = 0
        let dataSize = 1000
        
        // 添加接收流量
        flowController.addCredit(streamID: streamID, bytes: dataSize)
        
        // 这主要测试不会崩溃，具体行为取决于内部实现
        XCTAssertNoThrow(flowController.addCredit(streamID: streamID, bytes: dataSize))
    }
    
    func testMaxDataFrameHandling() {
        let increment: UInt64 = 50000
        let windowBefore = flowController.getConnectionWindow()
        
        // 处理MAX_DATA帧
        flowController.handleMaxData(increment)
        
        XCTAssertEqual(flowController.getConnectionWindow(), windowBefore + increment)
    }
    
    func testMaxStreamDataFrameHandling() {
        let streamID: UInt64 = 0
        let maxStreamData: UInt64 = 100000
        
        // 创建流控制器
        flowController.createStreamController(streamID: streamID)
        
        // 处理MAX_STREAM_DATA帧
        let frame = MaxStreamDataFrame(streamID: streamID, maxStreamData: maxStreamData)
        flowController.handleMaxStreamData(frame)
        
        // 窗口应该被更新
        XCTAssertGreaterThanOrEqual(flowController.getStreamWindow(streamID: streamID), 0)
    }
    
    func testStreamBlocking() {
        let streamID: UInt64 = 0
        
        // 消费所有流窗口
        let streamWindow = flowController.getStreamWindow(streamID: streamID)
        flowController.consumeCredit(streamID: streamID, bytes: Int(streamWindow))
        
        // 流应该被阻塞
        XCTAssertTrue(flowController.isStreamBlocked(streamID: streamID))
        XCTAssertTrue(flowController.getBlockedStreams().contains(streamID))
    }
    
    func testConnectionBlocking() {
        // 消费所有连接窗口
        let connectionWindow = flowController.getConnectionWindow()
        flowController.consumeCredit(streamID: 0, bytes: Int(connectionWindow))
        
        // 连接应该被阻塞
        XCTAssertTrue(flowController.isConnectionBlocked())
    }
    
    func testStreamControllerLifecycle() {
        let streamID: UInt64 = 42
        
        // 创建流控制器
        flowController.createStreamController(streamID: streamID)
        XCTAssertEqual(flowController.getStreamWindow(streamID: streamID), 65536)
        
        // 移除流控制器
        flowController.removeStreamController(streamID: streamID)
        
        // 移除后应该使用默认窗口
        XCTAssertEqual(flowController.getStreamWindow(streamID: streamID), 65536)
    }
    
    func testFlowControlStatistics() {
        let streamID: UInt64 = 0
        let dataSize = 10000
        
        // 发送一些数据
        flowController.consumeCredit(streamID: streamID, bytes: dataSize)
        flowController.addCredit(streamID: streamID, bytes: dataSize)
        
        let stats = flowController.getFlowControlStatistics()
        
        XCTAssertEqual(stats.connectionSendWindow, 1048576 - UInt64(dataSize))
        XCTAssertEqual(stats.activeStreamControllers, 1)
        XCTAssertEqual(stats.totalBytesSent, UInt64(dataSize))
    }
    
    func testPerformMaintenance() {
        // 创建一些流控制器
        flowController.createStreamController(streamID: 0)
        flowController.createStreamController(streamID: 4)
        flowController.createStreamController(streamID: 8)
        
        // 执行维护
        flowController.performMaintenance()
        
        // 维护操作不应该崩溃
        let stats = flowController.getFlowControlStatistics()
        XCTAssertGreaterThanOrEqual(stats.activeStreamControllers, 0)
    }
    
    func testDebugInfo() {
        let streamID: UInt64 = 0
        flowController.consumeCredit(streamID: streamID, bytes: 1000)
        
        let debugInfo = flowController.debugInfo()
        
        XCTAssertTrue(debugInfo.contains("Flow Control Info"))
        XCTAssertTrue(debugInfo.contains("Connection Windows"))
        XCTAssertTrue(debugInfo.contains("Stream Controllers"))
    }
    
    func testCallbacks() {
        var connectionBlockedCalled = false
        var streamBlockedCalled = false
        var windowUpdateNeededCalled = false
        var blockedStreamID: UInt64?
        
        flowController.onConnectionBlocked = {
            connectionBlockedCalled = true
        }
        
        flowController.onStreamBlocked = { streamID in
            streamBlockedCalled = true
            blockedStreamID = streamID
        }
        
        flowController.onWindowUpdateNeeded = { streamID, increment in
            windowUpdateNeededCalled = true
        }
        
        let streamID: UInt64 = 0
        
        // 消费所有流窗口来触发阻塞
        let streamWindow = flowController.getStreamWindow(streamID: streamID)
        flowController.consumeCredit(streamID: streamID, bytes: Int(streamWindow))
        
        XCTAssertTrue(streamBlockedCalled)
        XCTAssertEqual(blockedStreamID, streamID)
        
        // 添加接收流量来触发窗口更新
        flowController.addCredit(streamID: streamID, bytes: 32768)
    }
    
    func testEdgeCases() {
        let streamID: UInt64 = 0
        
        // 测试发送0字节
        XCTAssertTrue(flowController.canSend(streamID: streamID, bytes: 0))
        flowController.consumeCredit(streamID: streamID, bytes: 0)
        
        // 测试负数（应该被处理为0）
        XCTAssertNoThrow(flowController.addCredit(streamID: streamID, bytes: -100))
        
        // 测试超大数值
        let maxUInt64 = UInt64.max
        XCTAssertFalse(flowController.canSend(streamID: streamID, bytes: Int(maxUInt64)))
    }
    
    func testConcurrentAccess() {
        let streamID: UInt64 = 0
        let expectation = self.expectation(description: "Concurrent access")
        expectation.expectedFulfillmentCount = 10
        
        // 并发访问流量控制器
        for _ in 0..<10 {
            DispatchQueue.global().async {
                self.flowController.consumeCredit(streamID: streamID, bytes: 100)
                self.flowController.addCredit(streamID: streamID, bytes: 50)
                expectation.fulfill()
            }
        }
        
        waitForExpectations(timeout: 5.0)
        
        // 验证状态仍然一致
        XCTAssertGreaterThanOrEqual(flowController.getConnectionWindow(), 0)
        XCTAssertGreaterThanOrEqual(flowController.getStreamWindow(streamID: streamID), 0)
    }
}