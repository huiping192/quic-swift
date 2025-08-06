import XCTest
@testable import QUICSwift

class LossAndCongestionManagerTests: XCTestCase {
    var manager: LossAndCongestionManager!
    var delegateEvents: [String] = []
    
    override func setUp() {
        super.setUp()
        manager = LossAndCongestionManager.createWithNewReno(initialWindow: 12000)
        manager.delegate = self
        delegateEvents.removeAll()
    }
    
    override func tearDown() {
        manager = nil
        delegateEvents.removeAll()
        super.tearDown()
    }
    
    // MARK: - 基础功能测试
    
    func testInitialState() {
        XCTAssertEqual(manager.congestionWindow, 12000)
        XCTAssertEqual(manager.bytesInFlight, 0)
        XCTAssertEqual(manager.pendingPacketCount, 0)
        XCTAssertTrue(manager.canSend(bytes: 1200))
        XCTAssertEqual(manager.availableWindow, 12000)
    }
    
    func testPacketSending() {
        let packet = SentPacket(
            packetNumber: 1,
            sentTime: Date(),
            size: 1200,
            packetSpace: .application,
            frames: [],
            isAckEliciting: true
        )
        
        manager.onPacketSent(packet)
        
        XCTAssertEqual(manager.bytesInFlight, 1200)
        XCTAssertEqual(manager.pendingPacketCount, 1)
        XCTAssertEqual(manager.availableWindow, 10800)
        XCTAssertTrue(delegateEvents.contains("packet_sent"))
    }
    
    // MARK: - 包确认和丢包处理测试
    
    func testPacketAcknowledgment() {
        // 发送包
        let sentPacket = SentPacket(
            packetNumber: 1,
            sentTime: Date(),
            size: 1200,
            packetSpace: .application,
            frames: [],
            isAckEliciting: true
        )
        
        manager.onPacketSent(sentPacket)
        
        // 确认包
        let ackedPacket = AckedPacket(
            packetNumber: 1,
            sentTime: sentPacket.sentTime,
            size: 1200,
            ackedTime: Date(),
            packetSpace: .application
        )
        
        manager.onPacketAcknowledged(ackedPackets: [ackedPacket])
        
        XCTAssertEqual(manager.bytesInFlight, 0)
        XCTAssertEqual(manager.pendingPacketCount, 0)
        XCTAssertGreaterThan(manager.congestionWindow, 12000) // 慢启动应该增长
        XCTAssertTrue(delegateEvents.contains("packets_acknowledged"))
    }
    
    func testPacketLossDetection() {
        // 发送多个包
        let packets = (1...5).map { i in
            SentPacket(
                packetNumber: UInt64(i),
                sentTime: Date(),
                size: 1200,
                packetSpace: .application,
                frames: [],
                isAckEliciting: true
            )
        }
        
        for packet in packets {
            manager.onPacketSent(packet)
        }
        
        // 确认部分包，导致丢包检测
        let ackedPackets = [
            AckedPacket(
                packetNumber: 4,
                sentTime: packets[3].sentTime,
                size: 1200,
                ackedTime: Date(),
                packetSpace: .application
            )
        ]
        
        manager.onPacketAcknowledged(ackedPackets: ackedPackets)
        
        // 验证有包被检测为丢失
        XCTAssertLessThan(manager.pendingPacketCount, 5) // 有些包应该被处理了
        XCTAssertTrue(delegateEvents.contains("packet_loss"))
    }
    
    // MARK: - 拥塞控制集成测试
    
    func testCongestionResponse() {
        let initialWindow = manager.congestionWindow
        
        // 发送包
        let packet = SentPacket(
            packetNumber: 1,
            sentTime: Date(),
            size: 1200,
            packetSpace: .application,
            frames: [],
            isAckEliciting: true
        )
        
        manager.onPacketSent(packet)
        
        // 模拟丢包
        let lostPackets = [LostPacket(
            packetNumber: 1,
            sentTime: packet.sentTime,
            size: 1200,
            frames: [],
            packetSpace: .application,
            lostTime: Date()
        )]
        
        // 直接模拟丢包检测并处理 - 通过内部方法触发拥塞事件
        // 这会正确地减少拥塞窗口
        if let detector = manager as? LossDetectionDelegate {
            detector.lossDetector(LossDetector(), didDetectLoss: lostPackets)
        }
        
        // 拥塞窗口应该减小
        XCTAssertLessThan(manager.congestionWindow, initialWindow)
        XCTAssertTrue(delegateEvents.contains("packet_loss"))
    }
    
    // MARK: - 发送控制测试
    
    func testSendingControl() {
        // 填满窗口
        let windowSize = manager.congestionWindow
        let packetSize: UInt64 = 1200
        let packetsToSend = Int(windowSize / packetSize)
        
        for i in 1...packetsToSend {
            let packet = SentPacket(
                packetNumber: UInt64(i),
                sentTime: Date(),
                size: Int(packetSize),
                packetSpace: .application,
                frames: [],
                isAckEliciting: true
            )
            
            if manager.canSend(bytes: packetSize) {
                manager.onPacketSent(packet)
            }
        }
        
        // 现在应该不能再发送
        XCTAssertFalse(manager.canSend(bytes: 1200))
        XCTAssertEqual(manager.availableWindow, manager.congestionWindow - manager.bytesInFlight)
    }
    
    // MARK: - RTT测试
    
    func testRTTMeasurement() {
        let sentTime = Date()
        
        // 发送包
        let packet = SentPacket(
            packetNumber: 1,
            sentTime: sentTime,
            size: 1200,
            packetSpace: .application,
            frames: [],
            isAckEliciting: true
        )
        
        manager.onPacketSent(packet)
        
        // 确认包（100ms RTT）
        let ackedPacket = AckedPacket(
            packetNumber: 1,
            sentTime: sentTime,
            size: 1200,
            ackedTime: sentTime.addingTimeInterval(0.1),
            packetSpace: .application
        )
        
        manager.onPacketAcknowledged(ackedPackets: [ackedPacket])
        
        XCTAssertEqual(manager.smoothedRTT, 0.1, accuracy: 0.001)
        XCTAssertTrue(delegateEvents.contains("rtt_update"))
    }
    
    // MARK: - 批量处理测试
    
    func testBatchProcessing() {
        let packets: [(SentPacket, AckedPacket)] = (1...5).map { i in
            let sentTime = Date()
            let sent = SentPacket(
                packetNumber: UInt64(i),
                sentTime: sentTime,
                size: 1200,
                packetSpace: .application,
                frames: [],
                isAckEliciting: true
            )
            
            let acked = AckedPacket(
                packetNumber: UInt64(i),
                sentTime: sentTime,
                size: 1200,
                ackedTime: sentTime.addingTimeInterval(0.1),
                packetSpace: .application
            )
            
            return (sent, acked)
        }
        
        // 先发送所有包
        for (sent, _) in packets {
            manager.onPacketSent(sent)
        }
        
        // 批量确认
        manager.processBatchAcknowledgment(packets: packets)
        
        XCTAssertEqual(manager.bytesInFlight, 0)
        XCTAssertEqual(manager.pendingPacketCount, 0)
    }
    
    // MARK: - 发送建议测试
    
    func testSendingRecommendation() {
        let recommendation = manager.getSendingRecommendation()
        
        XCTAssertTrue(recommendation.shouldSend)
        XCTAssertEqual(recommendation.canSendBytes, 12000)
        XCTAssertEqual(recommendation.recommendedPacketSize, 1200)
        XCTAssertEqual(recommendation.priority, .high) // 慢启动状态
    }
    
    func testThrottlingDecision() {
        // 初始状态不应该限制
        XCTAssertFalse(manager.shouldThrottle())
        
        // 模拟高丢包率情况
        // 这里需要通过发送和丢失大量包来模拟
        for i in 1...20 {
            let packet = SentPacket(
                packetNumber: UInt64(i),
                sentTime: Date(),
                size: 1200,
                packetSpace: .application,
                frames: [],
                isAckEliciting: true
            )
            
            if manager.canSend(bytes: 1200) {
                manager.onPacketSent(packet)
            }
        }
        
        // 现在应该建议限制（窗口利用率高）
        XCTAssertTrue(manager.shouldThrottle())
    }
    
    // MARK: - 统计信息测试
    
    func testStatistics() {
        // 发送一些包
        for i in 1...3 {
            let packet = SentPacket(
                packetNumber: UInt64(i),
                sentTime: Date(),
                size: 1200,
                packetSpace: .application,
                frames: [],
                isAckEliciting: true
            )
            manager.onPacketSent(packet)
        }
        
        // 确认一些包
        let ackedPackets = [
            AckedPacket(
                packetNumber: 1,
                sentTime: Date(),
                size: 1200,
                ackedTime: Date(),
                packetSpace: .application
            ),
            AckedPacket(
                packetNumber: 2,
                sentTime: Date(),
                size: 1200,
                ackedTime: Date(),
                packetSpace: .application
            )
        ]
        
        manager.onPacketAcknowledged(ackedPackets: ackedPackets)
        
        let stats = manager.getStatistics()
        
        XCTAssertEqual(stats["total_packets_sent"] as? UInt64, 3)
        XCTAssertEqual(stats["total_packets_acked"] as? UInt64, 2)
        XCTAssertNotNil(stats["loss_rate"])
        XCTAssertNotNil(stats["delivery_rate"])
        XCTAssertNotNil(stats["congestion_window"])
        XCTAssertNotNil(stats["smoothed_rtt"])
    }
    
    // MARK: - 工厂方法测试
    
    func testFactoryMethods() {
        let newRenoManager = LossAndCongestionManager.createWithNewReno(initialWindow: 24000)
        XCTAssertEqual(newRenoManager.congestionWindow, 24000)
        
        let enhancedManager = LossAndCongestionManager.createWithEnhancedNewReno()
        XCTAssertGreaterThan(enhancedManager.congestionWindow, 0)
    }
}

// MARK: - 代理实现
extension LossAndCongestionManagerTests: LossAndCongestionDelegate {
    func lossAndCongestionManager(_ manager: LossAndCongestionManager, didSendPacket packet: SentPacket) {
        delegateEvents.append("packet_sent")
    }
    
    func lossAndCongestionManager(_ manager: LossAndCongestionManager, didAcknowledgePackets packets: [AckedPacket], withLostPackets lostPackets: [LostPacket]) {
        delegateEvents.append("packets_acknowledged")
        if !lostPackets.isEmpty {
            delegateEvents.append("packet_loss")
        }
    }
    
    func lossAndCongestionManager(_ manager: LossAndCongestionManager, didDetectPacketLoss lostPackets: [LostPacket]) {
        delegateEvents.append("packet_loss")
    }
    
    func lossAndCongestionManager(_ manager: LossAndCongestionManager, didUpdateRTT samples: [RTTSample]) {
        delegateEvents.append("rtt_update")
    }
}