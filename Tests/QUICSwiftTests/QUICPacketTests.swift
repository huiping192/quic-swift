import XCTest
@testable import QUICSwift

final class QUICPacketTests: XCTestCase {
    
    func testConnectionIDCreation() {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let connectionID = ConnectionID(bytes: bytes)
        
        XCTAssertEqual(connectionID.bytes, bytes)
        XCTAssertEqual(connectionID.length, 4)
        XCTAssertFalse(connectionID.isEmpty)
    }
    
    func testEmptyConnectionID() {
        let emptyID = ConnectionID.empty
        
        XCTAssertTrue(emptyID.isEmpty)
        XCTAssertEqual(emptyID.length, 0)
        XCTAssertEqual(emptyID.bytes.count, 0)
    }
    
    func testConnectionIDEquality() {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let id1 = ConnectionID(bytes: bytes)
        let id2 = ConnectionID(bytes: bytes)
        let id3 = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x05]))
        
        XCTAssertEqual(id1, id2)
        XCTAssertNotEqual(id1, id3)
    }
    
    func testQUICPacketInitialCreation() {
        let destCID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let srcCID = ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let payload = "Hello QUIC".data(using: .utf8)!
        
        let packet = QUICPacket(
            headerForm: .long,
            packetType: .initial,
            version: QUICVersion.current,
            destinationConnectionID: destCID,
            sourceConnectionID: srcCID,
            packetNumber: 0,
            payload: payload
        )
        
        XCTAssertEqual(packet.headerForm, .long)
        XCTAssertEqual(packet.packetType, .initial)
        XCTAssertEqual(packet.version, QUICVersion.current)
        XCTAssertEqual(packet.destinationConnectionID, destCID)
        XCTAssertEqual(packet.sourceConnectionID, srcCID)
        XCTAssertEqual(packet.packetNumber, 0)
        XCTAssertEqual(packet.payload, payload)
    }
    
    func testQUICPacketSerialization() {
        let destCID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let srcCID = ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let payload = Data([0xAA, 0xBB, 0xCC])
        
        let packet = QUICPacket(
            headerForm: .long,
            packetType: .initial,
            version: QUICVersion.current,
            destinationConnectionID: destCID,
            sourceConnectionID: srcCID,
            packetNumber: 123,
            payload: payload
        )
        
        let serialized = packet.serialize()
        XCTAssertFalse(serialized.isEmpty)
        
        // 验证包头的第一个字节
        let firstByte = serialized[0]
        XCTAssertEqual(firstByte & 0x80, 0x80) // Header Form = 1
        XCTAssertEqual(firstByte & 0x40, 0x40) // Fixed Bit = 1
    }
    
    func testQUICPacketParsing() throws {
        // 创建一个简单的Initial包
        var builder = PacketBuilder()
        
        // 第一字节：长包头 + Fixed Bit + Initial类型
        builder.writeUInt8(0xC0) // 1100 0000 = Header Form(1) + Fixed Bit(1) + Type(00) + PN Length(00)
        
        // 版本
        builder.writeUInt32(QUICVersion.current)
        
        // 连接ID长度
        builder.writeUInt8(0x44) // 4字节目标CID + 4字节源CID
        
        // 连接IDs
        builder.writeBytes(Data([0x01, 0x02, 0x03, 0x04])) // 目标CID
        builder.writeBytes(Data([0x05, 0x06, 0x07, 0x08])) // 源CID
        
        // Token长度（0）
        builder.writeVariableInt(0)
        
        // 长度字段（包号长度1 + 载荷长度3）
        builder.writeVariableInt(4)
        
        // 包号
        builder.writePacketNumber(0, length: 1)
        
        // 载荷
        builder.writeBytes(Data([0xAA, 0xBB, 0xCC]))
        
        let packetData = builder.build()
        let parsedPacket = try QUICPacket.parse(from: packetData)
        
        XCTAssertEqual(parsedPacket.headerForm, .long)
        XCTAssertEqual(parsedPacket.packetType, .initial)
        XCTAssertEqual(parsedPacket.version, QUICVersion.current)
        XCTAssertEqual(parsedPacket.destinationConnectionID.bytes, Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(parsedPacket.sourceConnectionID?.bytes, Data([0x05, 0x06, 0x07, 0x08]))
        XCTAssertEqual(parsedPacket.packetNumber, 0)
        XCTAssertEqual(parsedPacket.payload, Data([0xAA, 0xBB, 0xCC]))
    }
    
    func testVersionNegotiationPacketParsing() throws {
        var builder = PacketBuilder()
        
        // 第一字节：长包头
        builder.writeUInt8(0xC0)
        
        // 版本协商标识
        builder.writeUInt32(QUICVersion.negotiation)
        
        // 连接ID长度
        builder.writeUInt8(0x44) // 4字节目标CID + 4字节源CID
        
        // 连接IDs
        builder.writeBytes(Data([0x01, 0x02, 0x03, 0x04]))
        builder.writeBytes(Data([0x05, 0x06, 0x07, 0x08]))
        
        // 支持的版本列表
        builder.writeUInt32(QUICVersion.current)
        
        let packetData = builder.build()
        let parsedPacket = try QUICPacket.parse(from: packetData)
        
        XCTAssertEqual(parsedPacket.headerForm, .long)
        XCTAssertNil(parsedPacket.packetType)
        XCTAssertEqual(parsedPacket.version, QUICVersion.negotiation)
        XCTAssertEqual(parsedPacket.packetNumber, 0)
        
        // 验证版本列表
        let versions = try VersionNegotiation.extractVersionsFromNegotiationPacket(parsedPacket)
        XCTAssertEqual(versions, [QUICVersion.current])
    }
    
    func testShortHeaderPacketParsing() throws {
        var builder = PacketBuilder()
        
        // 第一字节：短包头
        builder.writeUInt8(0x43) // 0100 0011 = Header Form(0) + Fixed Bit(1) + Spin(0) + Reserved(0) + Key Phase(0) + PN Length(11=4bytes)
        
        // 目标连接ID（8字节）
        builder.writeBytes(Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
        
        // 包号（4字节）
        builder.writePacketNumber(123, length: 4)
        
        // 载荷
        builder.writeBytes(Data([0xAA, 0xBB, 0xCC, 0xDD]))
        
        let packetData = builder.build()
        let parsedPacket = try QUICPacket.parse(from: packetData)
        
        XCTAssertEqual(parsedPacket.headerForm, .short)
        XCTAssertNil(parsedPacket.packetType)
        XCTAssertNil(parsedPacket.version)
        XCTAssertEqual(parsedPacket.destinationConnectionID.bytes, Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
        XCTAssertNil(parsedPacket.sourceConnectionID)
        XCTAssertEqual(parsedPacket.packetNumber, 123)
        XCTAssertEqual(parsedPacket.payload, Data([0xAA, 0xBB, 0xCC, 0xDD]))
    }
    
    func testInvalidPacketParsing() {
        // 测试空数据
        XCTAssertThrowsError(try QUICPacket.parse(from: Data())) { error in
            XCTAssertTrue(error is QUICError)
        }
        
        // 测试Invalid Fixed Bit
        let invalidData = Data([0x80]) // Header Form=1, Fixed Bit=0
        XCTAssertThrowsError(try QUICPacket.parse(from: invalidData)) { error in
            XCTAssertEqual(error as? QUICError, .invalidFixedBit)
        }
    }
    
    func testUnsupportedVersion() {
        var builder = PacketBuilder()
        
        builder.writeUInt8(0xC0)
        builder.writeUInt32(0xDEADBEEF) // 不支持的版本
        builder.writeUInt8(0x00) // 连接ID长度为0
        builder.writeVariableInt(0) // Token长度
        builder.writeVariableInt(1) // 长度
        builder.writeUInt8(0) // 包号
        
        let packetData = builder.build()
        
        XCTAssertThrowsError(try QUICPacket.parse(from: packetData)) { error in
            if case .unsupportedVersion(let version) = error as? QUICError {
                XCTAssertEqual(version, 0xDEADBEEF)
            } else {
                XCTFail("Expected unsupportedVersion error")
            }
        }
    }
    
    func testPacketRoundTrip() throws {
        let destCID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let srcCID = ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let payload = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
        
        let originalPacket = QUICPacket(
            headerForm: .long,
            packetType: .handshake,
            version: QUICVersion.current,
            destinationConnectionID: destCID,
            sourceConnectionID: srcCID,
            packetNumber: 456,
            payload: payload
        )
        
        let serialized = originalPacket.serialize()
        let parsedPacket = try QUICPacket.parse(from: serialized)
        
        XCTAssertEqual(parsedPacket.headerForm, originalPacket.headerForm)
        XCTAssertEqual(parsedPacket.packetType, originalPacket.packetType)
        XCTAssertEqual(parsedPacket.version, originalPacket.version)
        XCTAssertEqual(parsedPacket.destinationConnectionID, originalPacket.destinationConnectionID)
        XCTAssertEqual(parsedPacket.sourceConnectionID, originalPacket.sourceConnectionID)
        XCTAssertEqual(parsedPacket.payload, originalPacket.payload)
    }
    
    func testPacketDebugDescription() {
        let destCID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let srcCID = ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let payload = Data([0xAA, 0xBB])
        
        let packet = QUICPacket(
            headerForm: .long,
            packetType: .initial,
            version: QUICVersion.current,
            destinationConnectionID: destCID,
            sourceConnectionID: srcCID,
            packetNumber: 123,
            payload: payload
        )
        
        let description = packet.debugDescription
        XCTAssertTrue(description.contains("QUIC Packet"))
        XCTAssertTrue(description.contains("Long Header"))
        XCTAssertTrue(description.contains("Initial"))
        XCTAssertTrue(description.contains("123"))
        XCTAssertTrue(description.contains("2")) // payload length
    }
}