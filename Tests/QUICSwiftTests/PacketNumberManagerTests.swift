import XCTest
@testable import QUICSwift

final class PacketNumberManagerTests: XCTestCase {
    var manager: PacketNumberManager!
    
    override func setUp() {
        super.setUp()
        manager = PacketNumberManager()
    }
    
    override func tearDown() {
        manager = nil
        super.tearDown()
    }
    
    func testPacketNumberGeneration() {
        let pn1 = manager.nextPacketNumber(for: .initial)
        let pn2 = manager.nextPacketNumber(for: .initial)
        let pn3 = manager.nextPacketNumber(for: .handshake)
        
        XCTAssertEqual(pn1, 0)
        XCTAssertEqual(pn2, 1)
        XCTAssertEqual(pn3, 0) // 不同空间独立计数
    }
    
    func testPacketNumberValidation() {
        // 新的包号应该有效
        XCTAssertTrue(manager.validatePacketNumber(0, in: .initial))
        XCTAssertTrue(manager.validatePacketNumber(100, in: .initial))
        
        // 标记包号为已接收
        _ = manager.markReceived(0, in: .initial)
        
        // 已接收的包号应该无效
        XCTAssertFalse(manager.validatePacketNumber(0, in: .initial))
        
        // 未接收的包号仍然有效
        XCTAssertTrue(manager.validatePacketNumber(1, in: .initial))
    }
    
    func testPacketNumberMarking() {
        let wasNew1 = manager.markReceived(0, in: .initial)
        let wasNew2 = manager.markReceived(0, in: .initial) // 重复标记
        let wasNew3 = manager.markReceived(1, in: .initial)
        
        XCTAssertTrue(wasNew1)
        XCTAssertFalse(wasNew2) // 重复标记应该返回false
        XCTAssertTrue(wasNew3)
    }
    
    func testPacketSpaceIndependence() {
        // 在不同空间中标记相同的包号
        _ = manager.markReceived(0, in: .initial)
        _ = manager.markReceived(0, in: .handshake)
        _ = manager.markReceived(0, in: .application)
        
        // 验证每个空间都记录了包号0
        let initialStats = manager.getStatistics(for: .initial)
        let handshakeStats = manager.getStatistics(for: .handshake)
        let applicationStats = manager.getStatistics(for: .application)
        
        XCTAssertEqual(initialStats?.receivedPacketsCount, 1)
        XCTAssertEqual(handshakeStats?.receivedPacketsCount, 1)
        XCTAssertEqual(applicationStats?.receivedPacketsCount, 1)
    }
    
    func testSpaceStateTracking() {
        _ = manager.nextPacketNumber(for: .initial)
        _ = manager.nextPacketNumber(for: .initial)
        _ = manager.markReceived(5, in: .initial)
        _ = manager.markReceived(10, in: .initial)
        
        let stats = manager.getStatistics(for: .initial)!
        
        XCTAssertEqual(stats.nextPacketNumber, 2)
        XCTAssertEqual(stats.largestReceived, 10)
        XCTAssertEqual(stats.maxReceived, 10)
        XCTAssertEqual(stats.receivedPacketsCount, 2)
    }
    
    func testSpaceReset() {
        _ = manager.nextPacketNumber(for: .initial)
        _ = manager.markReceived(5, in: .initial)
        
        var stats = manager.getStatistics(for: .initial)!
        XCTAssertEqual(stats.nextPacketNumber, 1)
        XCTAssertEqual(stats.receivedPacketsCount, 1)
        
        manager.resetSpace(.initial)
        
        stats = manager.getStatistics(for: .initial)!
        XCTAssertEqual(stats.nextPacketNumber, 0)
        XCTAssertEqual(stats.receivedPacketsCount, 0)
    }
    
    func testAllSpacesStatistics() {
        _ = manager.nextPacketNumber(for: .initial)
        _ = manager.nextPacketNumber(for: .handshake)
        _ = manager.markReceived(0, in: .application)
        
        let allStats = manager.getAllStatistics()
        
        XCTAssertEqual(allStats.count, 3)
        XCTAssertNotNil(allStats[.initial])
        XCTAssertNotNil(allStats[.handshake])
        XCTAssertNotNil(allStats[.application])
        
        XCTAssertEqual(allStats[.initial]?.nextPacketNumber, 1)
        XCTAssertEqual(allStats[.handshake]?.nextPacketNumber, 1)
        XCTAssertEqual(allStats[.application]?.nextPacketNumber, 0)
        XCTAssertEqual(allStats[.application]?.receivedPacketsCount, 1)
    }
    
    func testPacketNumberCleanup() {
        // 标记一些包号
        for i in 0..<10 {
            _ = manager.markReceived(UInt64(i), in: .initial)
        }
        
        var stats = manager.getStatistics(for: .initial)!
        XCTAssertEqual(stats.receivedPacketsCount, 10)
        
        // 清理阈值为5以下的包号
        manager.cleanupOldPacketNumbers(in: .initial, olderThan: 5)
        
        stats = manager.getStatistics(for: .initial)!
        XCTAssertEqual(stats.receivedPacketsCount, 5) // 应该剩余5-9
    }
}

final class AdvancedPacketNumberManagerTests: XCTestCase {
    var manager: AdvancedPacketNumberManager!
    
    override func setUp() {
        super.setUp()
        manager = AdvancedPacketNumberManager()
    }
    
    override func tearDown() {
        manager = nil
        super.tearDown()
    }
    
    func testGapDetection() {
        // 接收包号 0, 2, 4（缺少1, 3）
        _ = manager.markReceived(0, in: .initial)
        _ = manager.markReceived(2, in: .initial)
        _ = manager.markReceived(4, in: .initial)
        
        let gaps = manager.detectGaps(in: .initial)
        
        // 应该检测到间隙：1和3
        XCTAssertFalse(gaps.isEmpty)
    }
    
    func testLostPacketDetection() {
        // 接收包号序列：0, 1, 2, 5, 6, 7
        // 包号3, 4应该被认为丢失
        for pn in [0, 1, 2, 5, 6, 7] {
            _ = manager.markReceived(UInt64(pn), in: .initial)
        }
        
        let lostPackets = manager.detectLostPackets(in: .initial, threshold: 3)
        
        // 由于largest_received是7，且间隙大于等于阈值3，包号3, 4应该被检测为丢失
        XCTAssertTrue(lostPackets.contains(3))
        XCTAssertTrue(lostPackets.contains(4))
    }
    
    func testPacketNumberCompression() {
        let largestAcked: UInt64 = 100
        
        // 测试1字节压缩
        let (compressed1, length1) = manager.compressPacketNumber(120, largestAcked: largestAcked)
        XCTAssertEqual(length1, 1)
        XCTAssertEqual(compressed1.count, 1)
        
        // 测试2字节压缩
        let (compressed2, length2) = manager.compressPacketNumber(400, largestAcked: largestAcked)
        XCTAssertEqual(length2, 2)
        XCTAssertEqual(compressed2.count, 2)
        
        // 测试4字节压缩
        let (compressed4, length4) = manager.compressPacketNumber(100000, largestAcked: largestAcked)
        XCTAssertEqual(length4, 4)
        XCTAssertEqual(compressed4.count, 4)
    }
    
    func testPacketNumberDecompression() {
        let largestAcked: UInt64 = 100
        let fullPacketNumber: UInt64 = 120
        
        // 压缩然后解压缩
        let (compressed, _) = manager.compressPacketNumber(fullPacketNumber, largestAcked: largestAcked)
        let decompressed = manager.decompressPacketNumber(compressed, largestAcked: largestAcked)
        
        XCTAssertEqual(decompressed, fullPacketNumber)
    }
    
    func testPacketNumberCompressionRoundTrip() {
        let largestAcked: UInt64 = 1000
        let testValues: [UInt64] = [1001, 1100, 2000, 10000, 100000]
        
        for originalValue in testValues {
            let (compressed, _) = manager.compressPacketNumber(originalValue, largestAcked: largestAcked)
            let decompressed = manager.decompressPacketNumber(compressed, largestAcked: largestAcked)
            
            XCTAssertEqual(decompressed, originalValue, "Round trip failed for value \(originalValue)")
        }
    }
    
    func testInvalidDecompression() {
        let largestAcked: UInt64 = 100
        
        // 空数据
        XCTAssertNil(manager.decompressPacketNumber(Data(), largestAcked: largestAcked))
        
        // 不完整的2字节数据
        XCTAssertNil(manager.decompressPacketNumber(Data([0x80]), largestAcked: largestAcked))
        
        // 不完整的3字节数据
        XCTAssertNil(manager.decompressPacketNumber(Data([0xC0, 0x01]), largestAcked: largestAcked))
        
        // 不完整的4字节数据
        XCTAssertNil(manager.decompressPacketNumber(Data([0xE0, 0x01, 0x02]), largestAcked: largestAcked))
    }
    
    func testLargeGapHandling() {
        // 创建一个很大的间隙
        _ = manager.markReceived(0, in: .initial)
        _ = manager.markReceived(1000000, in: .initial)
        
        let gaps = manager.detectGaps(in: .initial)
        XCTAssertFalse(gaps.isEmpty)
        
        // 应该能检测到大间隙
        let lostPackets = manager.detectLostPackets(in: .initial, threshold: 3)
        XCTAssertFalse(lostPackets.isEmpty)
    }
}