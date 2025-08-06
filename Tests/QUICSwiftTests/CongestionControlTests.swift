import XCTest
@testable import QUICSwift

class CongestionControlTests: XCTestCase {
    var congestionController: NewRenoCongestionController!
    
    override func setUp() {
        super.setUp()
        congestionController = NewRenoCongestionController(initialWindow: 12000) // 10 * MSS
    }
    
    override func tearDown() {
        congestionController = nil
        super.tearDown()
    }
    
    // MARK: - 初始化测试
    
    func testInitialState() {
        XCTAssertEqual(congestionController.congestionWindow, 12000)
        XCTAssertEqual(congestionController.slowStartThreshold, UInt64.max)
        XCTAssertEqual(congestionController.bytesInFlight, 0)
        XCTAssertTrue(congestionController.isInSlowStart)
        XCTAssertFalse(congestionController.isInFastRecovery)
    }
    
    func testCanSendInitially() {
        XCTAssertTrue(congestionController.canSend(bytes: 1200))
        XCTAssertTrue(congestionController.canSend(bytes: 12000))
        XCTAssertFalse(congestionController.canSend(bytes: 12001))
    }
    
    // MARK: - 包发送测试
    
    func testPacketSent() {
        let packet = SentPacket(
            packetNumber: 1,
            sentTime: Date(),
            size: 1200,
            packetSpace: .application,
            frames: [],
            isAckEliciting: true
        )
        
        congestionController.onPacketSent(packet: packet)
        
        XCTAssertEqual(congestionController.bytesInFlight, 1200)
        XCTAssertTrue(congestionController.canSend(bytes: 10800))
        XCTAssertFalse(congestionController.canSend(bytes: 10801))
    }
    
    func testMultiplePacketsSent() {
        for i in 1...5 {
            let packet = SentPacket(
                packetNumber: UInt64(i),
                sentTime: Date(),
                size: 1200,
                packetSpace: .application,
                frames: [],
                isAckEliciting: true
            )
            congestionController.onPacketSent(packet: packet)
        }
        
        XCTAssertEqual(congestionController.bytesInFlight, 6000)
        XCTAssertTrue(congestionController.canSend(bytes: 6000))
        XCTAssertFalse(congestionController.canSend(bytes: 6001))
    }
    
    // MARK: - 慢启动测试
    
    func testSlowStartGrowth() {
        let initialWindow = congestionController.congestionWindow
        
        // 发送和确认一个包
        let sentPacket = SentPacket(
            packetNumber: 1,
            sentTime: Date(),
            size: 1200,
            packetSpace: .application,
            frames: [],
            isAckEliciting: true
        )
        
        congestionController.onPacketSent(packet: sentPacket)
        
        let ackedPacket = AckedPacket(
            packetNumber: 1,
            sentTime: sentPacket.sentTime,
            size: 1200,
            ackedTime: Date(),
            packetSpace: .application
        )
        
        congestionController.onPacketAcked(packet: ackedPacket, rtt: 0.1)
        
        // 慢启动应该增加窗口大小
        XCTAssertEqual(congestionController.congestionWindow, initialWindow + 1200)
        XCTAssertEqual(congestionController.bytesInFlight, 0)
        XCTAssertTrue(congestionController.isInSlowStart)
    }
    
    func testSlowStartToCongestAvoidanceTransition() {
        // 简单测试：触发拥塞事件后应该不再处于慢启动状态
        XCTAssertTrue(congestionController.isInSlowStart)
        
        // 触发拥塞事件（这会导致状态转换到快速恢复，然后可能转换到拥塞避免）
        congestionController.onCongestionEvent()
        
        // 验证不再处于慢启动状态（可能在快速恢复或拥塞避免状态）
        XCTAssertFalse(congestionController.isInSlowStart)
        XCTAssertLessThan(congestionController.slowStartThreshold, UInt64.max)
    }
    
    // MARK: - 拥塞避免测试
    
    func testCongestionAvoidanceGrowth() {
        // 强制进入拥塞避免状态
        forceCongestionAvoidanceState()
        
        let initialWindow = congestionController.congestionWindow
        let packetSize: UInt64 = 1200
        
        // 在拥塞避免阶段，窗口增长应该更保守
        for i in 1...10 {
            let sentPacket = SentPacket(
                packetNumber: UInt64(i),
                sentTime: Date(),
                size: Int(packetSize),
                packetSpace: .application,
                frames: [],
                isAckEliciting: true
            )
            
            congestionController.onPacketSent(packet: sentPacket)
            
            let ackedPacket = AckedPacket(
                packetNumber: UInt64(i),
                sentTime: sentPacket.sentTime,
                size: Int(packetSize),
                ackedTime: Date(),
                packetSpace: .application
            )
            
            congestionController.onPacketAcked(packet: ackedPacket, rtt: 0.1)
        }
        
        // 窗口应该有所增长，但比慢启动慢
        XCTAssertGreaterThan(congestionController.congestionWindow, initialWindow)
        // 在拥塞避免阶段，10个ACK应该增长不到10个MSS
        XCTAssertLessThanOrEqual(congestionController.congestionWindow, initialWindow + 10 * packetSize)
    }
    
    // MARK: - 丢包和拥塞事件测试
    
    func testPacketLoss() {
        let initialWindow = congestionController.congestionWindow
        
        let packet = SentPacket(
            packetNumber: 1,
            sentTime: Date(),
            size: 1200,
            packetSpace: .application,
            frames: [],
            isAckEliciting: true
        )
        
        congestionController.onPacketSent(packet: packet)
        
        let lostPacket = LostPacket(
            packetNumber: 1,
            sentTime: packet.sentTime,
            size: 1200,
            frames: [],
            packetSpace: .application,
            lostTime: Date()
        )
        
        congestionController.onPacketLost(packet: lostPacket)
        
        // 丢包应该触发拥塞控制
        XCTAssertLessThan(congestionController.congestionWindow, initialWindow)
        XCTAssertEqual(congestionController.bytesInFlight, 0)
        XCTAssertTrue(congestionController.isInFastRecovery)
    }
    
    func testCongestionEvent() {
        let initialWindow = congestionController.congestionWindow
        
        congestionController.onCongestionEvent()
        
        // 拥塞事件应该减少窗口大小
        XCTAssertLessThan(congestionController.congestionWindow, initialWindow)
        XCTAssertTrue(congestionController.isInFastRecovery)
        
        // 慢启动阈值应该被设置
        XCTAssertLessThan(congestionController.slowStartThreshold, UInt64.max)
    }
    
    // MARK: - 快速恢复测试
    
    func testFastRecovery() {
        // 简单测试快速恢复状态转换
        XCTAssertFalse(congestionController.isInFastRecovery)
        
        // 进入快速恢复
        congestionController.onCongestionEvent()
        
        // 验证状态变化
        XCTAssertTrue(congestionController.isInFastRecovery)
        XCTAssertLessThan(congestionController.slowStartThreshold, UInt64.max)
    }
    
    // MARK: - 工厂模式测试
    
    func testCongestionControllerFactory() {
        let controller = CongestionControllerFactory.create(.newReno)
        
        XCTAssertTrue(controller is NewRenoCongestionController)
        XCTAssertGreaterThan(controller.congestionWindow, 0)
    }
    
    func testCongestionControllerFactoryWithInitialWindow() {
        let customWindow: UInt64 = 24000
        let controller = CongestionControllerFactory.create(.newReno, initialWindow: customWindow)
        
        XCTAssertEqual(controller.congestionWindow, customWindow)
    }
    
    // MARK: - 统计信息测试
    
    func testStatistics() {
        let stats = congestionController.getStatistics()
        
        XCTAssertNotNil(stats["congestion_window"])
        XCTAssertNotNil(stats["slow_start_threshold"])
        XCTAssertNotNil(stats["bytes_in_flight"])
        XCTAssertNotNil(stats["state"])
        XCTAssertNotNil(stats["total_bytes_sent"])
        XCTAssertNotNil(stats["total_bytes_acked"])
        XCTAssertNotNil(stats["congestion_events"])
        XCTAssertNotNil(stats["utilization"])
        
        XCTAssertEqual(stats["congestion_window"] as? UInt64, congestionController.congestionWindow)
        XCTAssertEqual(stats["bytes_in_flight"] as? UInt64, 0)
        XCTAssertEqual(stats["state"] as? String, "Slow Start")
    }
    
    // MARK: - 边界条件测试
    
    func testMinimumWindow() {
        // 触发多次拥塞事件
        for _ in 1...10 {
            congestionController.onCongestionEvent()
        }
        
        // 窗口不应该小于最小值
        XCTAssertGreaterThanOrEqual(congestionController.congestionWindow, 2400) // 2 * MSS
    }
    
    func testZeroBytePacket() {
        let packet = SentPacket(
            packetNumber: 1,
            sentTime: Date(),
            size: 0,
            packetSpace: .application,
            frames: [],
            isAckEliciting: true
        )
        
        congestionController.onPacketSent(packet: packet)
        XCTAssertEqual(congestionController.bytesInFlight, 0)
        
        let ackedPacket = AckedPacket(
            packetNumber: 1,
            sentTime: packet.sentTime,
            size: 0,
            ackedTime: Date(),
            packetSpace: .application
        )
        
        // 零字节包的确认不应该崩溃
        XCTAssertNoThrow(congestionController.onPacketAcked(packet: ackedPacket, rtt: 0.1))
    }
    
    // MARK: - 辅助方法
    
    private func forceCongestionAvoidanceState() {
        // 通过触发拥塞事件并重置来设置较小的阈值
        congestionController.onCongestionEvent()
        let threshold = congestionController.slowStartThreshold
        congestionController.reset()
        
        // 手动设置状态（这里我们需要添加一个测试用的方法）
        // 或者通过发送足够的ACK来达到阈值
        var window = congestionController.congestionWindow
        var packetNum: UInt64 = 1
        
        while window < threshold {
            let sentPacket = SentPacket(
                packetNumber: packetNum,
                sentTime: Date(),
                size: 1200,
                packetSpace: .application,
                frames: [],
                isAckEliciting: true
            )
            
            congestionController.onPacketSent(packet: sentPacket)
            
            let ackedPacket = AckedPacket(
                packetNumber: packetNum,
                sentTime: sentPacket.sentTime,
                size: 1200,
                ackedTime: Date(),
                packetSpace: .application
            )
            
            congestionController.onPacketAcked(packet: ackedPacket, rtt: 0.1)
            window = congestionController.congestionWindow
            packetNum += 1
            
            if packetNum > 50 { break } // 防止无限循环
        }
    }
}

// MARK: - 增强拥塞控制器测试

class EnhancedCongestionControlTests: XCTestCase {
    var congestionController: EnhancedNewRenoCongestionController!
    var delegateEvents: [String] = []
    
    override func setUp() {
        super.setUp()
        congestionController = EnhancedNewRenoCongestionController()
        congestionController.delegate = self
        delegateEvents.removeAll()
    }
    
    override func tearDown() {
        congestionController = nil
        delegateEvents.removeAll()
        super.tearDown()
    }
    
    func testDelegateNotifications() {
        // 触发拥塞事件
        congestionController.onCongestionEvent()
        
        XCTAssertTrue(delegateEvents.contains("state_change"))
        XCTAssertTrue(delegateEvents.contains("congestion_detected"))
    }
    
    func testWindowChangeNotifications() {
        // 发送足够的包以触发窗口变化通知
        for i in 1...20 {
            let sentPacket = SentPacket(
                packetNumber: UInt64(i),
                sentTime: Date(),
                size: 1200,
                packetSpace: .application,
                frames: [],
                isAckEliciting: true
            )
            
            congestionController.onPacketSent(packet: sentPacket)
            
            let ackedPacket = AckedPacket(
                packetNumber: UInt64(i),
                sentTime: sentPacket.sentTime,
                size: 1200,
                ackedTime: Date(),
                packetSpace: .application
            )
            
            congestionController.onPacketAcked(packet: ackedPacket, rtt: 0.1)
        }
        
        XCTAssertTrue(delegateEvents.contains("window_change"))
    }
}

// MARK: - 代理实现

extension EnhancedCongestionControlTests: CongestionControlDelegate {
    func congestionController(_ controller: CongestionController, didChangeWindow newWindow: UInt64) {
        delegateEvents.append("window_change")
    }
    
    func congestionController(_ controller: CongestionController, didEnterState state: CongestionState) {
        delegateEvents.append("state_change")
    }
    
    func congestionController(_ controller: CongestionController, didDetectCongestion event: String) {
        delegateEvents.append("congestion_detected")
    }
}