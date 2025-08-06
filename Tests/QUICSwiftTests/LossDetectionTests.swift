import XCTest
@testable import QUICSwift

class LossDetectionTests: XCTestCase {
    var lossDetector: LossDetector!
    
    override func setUp() {
        super.setUp()
        lossDetector = LossDetector()
    }
    
    override func tearDown() {
        lossDetector = nil
        super.tearDown()
    }
    
    // MARK: - RTT更新测试
    
    func testRTTUpdate() {
        let sentTime = Date()
        let packet = SentPacket(
            packetNumber: 1,
            sentTime: sentTime,
            size: 1200,
            packetSpace: .application,
            frames: [],
            isAckEliciting: true
        )
        
        lossDetector.onPacketSent(packet)
        
        let ackedTime = sentTime.addingTimeInterval(0.1) // 100ms RTT
        let ackedPacket = AckedPacket(
            packetNumber: 1,
            sentTime: sentTime,
            size: 1200,
            ackedTime: ackedTime,
            packetSpace: .application
        )
        
        let result = lossDetector.onAckReceived(ackedPackets: [ackedPacket])
        
        XCTAssertEqual(result.rttSamples.count, 1)
        XCTAssertEqual(lossDetector.latestRTT, 0.1, accuracy: 0.001)
        XCTAssertEqual(lossDetector.smoothedRTT, 0.1, accuracy: 0.001)
    }
    
    func testMultipleRTTSamples() {
        let baseTime = Date()
        var packets: [SentPacket] = []
        var ackedPackets: [AckedPacket] = []
        
        // 发送多个包
        for i in 0..<5 {
            let sentTime = baseTime.addingTimeInterval(Double(i) * 0.01) // 10ms间隔
            let packet = SentPacket(
                packetNumber: UInt64(i),
                sentTime: sentTime,
                size: 1200,
                packetSpace: .application,
                frames: [],
                isAckEliciting: true
            )
            packets.append(packet)
            lossDetector.onPacketSent(packet)
        }
        
        // 确认所有包，RTT从50ms到150ms
        for (i, packet) in packets.enumerated() {
            let rtt = 0.05 + Double(i) * 0.025 // 50ms到150ms
            let ackedTime = packet.sentTime.addingTimeInterval(rtt)
            let ackedPacket = AckedPacket(
                packetNumber: packet.packetNumber,
                sentTime: packet.sentTime,
                size: packet.size,
                ackedTime: ackedTime,
                packetSpace: packet.packetSpace
            )
            ackedPackets.append(ackedPacket)
        }
        
        let result = lossDetector.onAckReceived(ackedPackets: ackedPackets)
        
        XCTAssertEqual(result.rttSamples.count, 5)
        XCTAssertTrue(lossDetector.smoothedRTT > 0)
        XCTAssertTrue(lossDetector.minRTT > 0)
    }
    
    // MARK: - 基于包间隔的丢包检测测试
    
    func testPacketThresholdLossDetection() {
        let baseTime = Date()
        
        // 发送5个包
        for i in 0..<5 {
            let packet = SentPacket(
                packetNumber: UInt64(i),
                sentTime: baseTime.addingTimeInterval(Double(i) * 0.01),
                size: 1200,
                packetSpace: .application,
                frames: ["test_frame"],
                isAckEliciting: true
            )
            lossDetector.onPacketSent(packet)
        }
        
        // 确认包3，这应该导致包0被认为丢失（包间距离正好是3）
        let ackedPackets = [
            AckedPacket(
                packetNumber: 3,
                sentTime: baseTime.addingTimeInterval(0.03),
                size: 1200,
                ackedTime: baseTime.addingTimeInterval(0.13),
                packetSpace: .application
            )
        ]
        
        let result = lossDetector.onAckReceived(ackedPackets: ackedPackets)
        
        
        XCTAssertEqual(result.lostPackets.count, 1)
        XCTAssertEqual(result.lostPackets.first?.packetNumber, 0)
    }
    
    // MARK: - 基于时间的丢包检测测试
    
    func testTimeBasedLossDetection() {
        let baseTime = Date()
        
        // 发送一个包
        let packet = SentPacket(
            packetNumber: 1,
            sentTime: baseTime,
            size: 1200,
            packetSpace: .application,
            frames: ["test_frame"],
            isAckEliciting: true
        )
        lossDetector.onPacketSent(packet)
        
        // 先确认一个包来建立RTT
        let rttPacket = SentPacket(
            packetNumber: 0,
            sentTime: baseTime.addingTimeInterval(-0.1),
            size: 1200,
            packetSpace: .application,
            frames: [],
            isAckEliciting: true
        )
        lossDetector.onPacketSent(rttPacket)
        
        let ackedPacket = AckedPacket(
            packetNumber: 0,
            sentTime: baseTime.addingTimeInterval(-0.1),
            size: 1200,
            ackedTime: baseTime,
            packetSpace: .application
        )
        
        _ = lossDetector.onAckReceived(ackedPackets: [ackedPacket])
        
        // 等待足够长的时间使包1超时
        let expectation = self.expectation(description: "Loss detection timeout")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // 这里应该通过定时器触发丢包检测，但为了测试，我们直接调用
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 0.5, handler: nil)
        
        // 验证统计信息
        // 包1应该因为超时而被检测为丢失，所以pending count应该为0
        XCTAssertEqual(lossDetector.pendingPacketCount, 0) // 包1已被检测为丢失
    }
    
    // MARK: - 性能和边界条件测试
    
    func testLargePacketNumbers() {
        let packet = SentPacket(
            packetNumber: UInt64.max - 1,
            sentTime: Date(),
            size: 1200,
            packetSpace: .application,
            frames: [],
            isAckEliciting: true
        )
        
        lossDetector.onPacketSent(packet)
        XCTAssertEqual(lossDetector.pendingPacketCount, 1)
        
        let ackedPacket = AckedPacket(
            packetNumber: UInt64.max - 1,
            sentTime: packet.sentTime,
            size: 1200,
            ackedTime: packet.sentTime.addingTimeInterval(0.1),
            packetSpace: .application
        )
        
        let result = lossDetector.onAckReceived(ackedPackets: [ackedPacket])
        XCTAssertEqual(result.lostPackets.count, 0)
        XCTAssertEqual(lossDetector.pendingPacketCount, 0)
    }
    
    func testEmptyAckList() {
        let packet = SentPacket(
            packetNumber: 1,
            sentTime: Date(),
            size: 1200,
            packetSpace: .application,
            frames: [],
            isAckEliciting: true
        )
        
        lossDetector.onPacketSent(packet)
        let result = lossDetector.onAckReceived(ackedPackets: [])
        
        XCTAssertEqual(result.lostPackets.count, 0)
        XCTAssertEqual(result.rttSamples.count, 0)
        XCTAssertEqual(lossDetector.pendingPacketCount, 1)
    }
    
    func testDifferentPacketSpaces() {
        let initialPacket = SentPacket(
            packetNumber: 1,
            sentTime: Date(),
            size: 1200,
            packetSpace: .initial,
            frames: [],
            isAckEliciting: true
        )
        
        let appPacket = SentPacket(
            packetNumber: 1,
            sentTime: Date(),
            size: 1200,
            packetSpace: .application,
            frames: [],
            isAckEliciting: true
        )
        
        lossDetector.onPacketSent(initialPacket)
        lossDetector.onPacketSent(appPacket)
        
        XCTAssertEqual(lossDetector.pendingPacketCount, 2)
        
        // 确认应用层包不应该影响初始包的丢包检测
        let ackedPacket = AckedPacket(
            packetNumber: 1,
            sentTime: appPacket.sentTime,
            size: 1200,
            ackedTime: Date(),
            packetSpace: .application
        )
        
        let result = lossDetector.onAckReceived(ackedPackets: [ackedPacket])
        
        XCTAssertEqual(result.lostPackets.count, 0) // 不同包空间，不会导致丢包
        XCTAssertEqual(lossDetector.pendingPacketCount, 1) // 初始包仍然待定
    }
    
    // MARK: - 统计信息测试
    
    func testStatistics() {
        let stats = lossDetector.getStatistics()
        
        XCTAssertNotNil(stats["smoothed_rtt"])
        XCTAssertNotNil(stats["latest_rtt"])
        XCTAssertNotNil(stats["min_rtt"])
        XCTAssertNotNil(stats["rtt_variation"])
        XCTAssertNotNil(stats["retransmission_timeout"])
        XCTAssertNotNil(stats["pending_packets"])
        
        XCTAssertEqual(stats["pending_packets"] as? Int, 0)
    }
    
    func testRTTSampleCalculation() {
        let _ = Date()
        let _ = Date().addingTimeInterval(0.1)
        let ackDelay: TimeInterval = 0.01
        
        let sample = RTTSample(rtt: 0.1, ackDelay: ackDelay)
        
        XCTAssertEqual(sample.rtt, 0.1, accuracy: 0.001)
        XCTAssertEqual(sample.ackDelay, 0.01, accuracy: 0.001)
        XCTAssertEqual(sample.adjustedRTT, 0.09, accuracy: 0.001) // 100ms - 10ms
    }
}