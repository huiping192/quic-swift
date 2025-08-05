import XCTest
@testable import QUICSwift

final class PacketParserTests: XCTestCase {
    
    func testReadUInt8() throws {
        let data = Data([0x42])
        var parser = PacketParser(data: data)
        
        let value = try parser.readUInt8()
        XCTAssertEqual(value, 0x42)
    }
    
    func testReadUInt16() throws {
        let data = Data([0x12, 0x34])
        var parser = PacketParser(data: data)
        
        let value = try parser.readUInt16()
        XCTAssertEqual(value, 0x1234)
    }
    
    func testReadUInt32() throws {
        let data = Data([0x12, 0x34, 0x56, 0x78])
        var parser = PacketParser(data: data)
        
        let value = try parser.readUInt32()
        XCTAssertEqual(value, 0x12345678)
    }
    
    func testReadUInt64() throws {
        let data = Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0])
        var parser = PacketParser(data: data)
        
        let value = try parser.readUInt64()
        XCTAssertEqual(value, 0x123456789ABCDEF0)
    }
    
    func testReadVariableInt1Byte() throws {
        let data = Data([0x25]) // 6-bit value: 37
        var parser = PacketParser(data: data)
        
        let value = try parser.readVariableInt()
        XCTAssertEqual(value, 37)
    }
    
    func testReadVariableInt2Bytes() throws {
        let data = Data([0x7B, 0xBD]) // 14-bit value: 15293
        var parser = PacketParser(data: data)
        
        let value = try parser.readVariableInt()
        XCTAssertEqual(value, 15293)
    }
    
    func testReadVariableInt4Bytes() throws {
        let data = Data([0x9D, 0x7F, 0x3E, 0x7D]) // 30-bit value: 494878333
        var parser = PacketParser(data: data)
        
        let value = try parser.readVariableInt()
        XCTAssertEqual(value, 494878333)
    }
    
    func testReadVariableInt8Bytes() throws {
        let data = Data([0xC2, 0x19, 0x7C, 0x5E, 0xFF, 0x14, 0xE8, 0x8C]) // 62-bit value
        var parser = PacketParser(data: data)
        
        let value = try parser.readVariableInt()
        XCTAssertEqual(value, 151288809941952652)
    }
    
    func testReadBytes() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        var parser = PacketParser(data: data)
        
        let bytes = try parser.readBytes(count: 3)
        XCTAssertEqual(bytes, Data([0x01, 0x02, 0x03]))
        
        let remainingBytes = try parser.readBytes(count: 2)
        XCTAssertEqual(remainingBytes, Data([0x04, 0x05]))
    }
    
    func testReadPacketNumber() throws {
        let data = Data([0x12, 0x34, 0x56, 0x78])
        var parser = PacketParser(data: data)
        
        let pn1 = try parser.readPacketNumber(length: 1)
        XCTAssertEqual(pn1, 0x12)
        
        parser.reset()
        let pn2 = try parser.readPacketNumber(length: 2)
        XCTAssertEqual(pn2, 0x1234)
        
        parser.reset()
        let pn4 = try parser.readPacketNumber(length: 4)
        XCTAssertEqual(pn4, 0x12345678)
    }
    
    func testInsufficientDataError() {
        let data = Data([0x01])
        var parser = PacketParser(data: data)
        
        XCTAssertThrowsError(try parser.readUInt16()) { error in
            XCTAssertTrue(error is ParsingError)
            XCTAssertEqual(error as? ParsingError, .insufficientData)
        }
    }
    
    func testHasMoreData() throws {
        var parser = PacketParser(data: Data([0x01, 0x02]))
        
        XCTAssertTrue(parser.hasMoreData)
        _ = try parser.readUInt8()
        
        XCTAssertTrue(parser.hasMoreData)
        _ = try parser.readUInt8()
        
        XCTAssertFalse(parser.hasMoreData)
    }
    
    func testRemainingBytes() throws {
        var parser = PacketParser(data: Data([0x01, 0x02, 0x03]))
        
        XCTAssertEqual(parser.remainingBytes, 3)
        _ = try parser.readUInt8()
        
        XCTAssertEqual(parser.remainingBytes, 2)
        _ = try parser.readUInt16()
        
        XCTAssertEqual(parser.remainingBytes, 0)
    }
    
    func testSkipBytes() throws {
        var parser = PacketParser(data: Data([0x01, 0x02, 0x03, 0x04]))
        
        try parser.skip(bytes: 2)
        let value = try parser.readUInt8()
        XCTAssertEqual(value, 0x03)
    }
    
    func testPeek() throws {
        let parser = PacketParser(data: Data([0x01, 0x02, 0x03]))
        
        let value1 = try parser.peek(at: 0)
        XCTAssertEqual(value1, 0x01)
        
        let value2 = try parser.peek(at: 2)
        XCTAssertEqual(value2, 0x03)
        
        XCTAssertThrowsError(try parser.peek(at: 10)) { error in
            XCTAssertEqual(error as? ParsingError, .invalidOffset)
        }
    }
}

final class PacketBuilderTests: XCTestCase {
    
    func testWriteUInt8() {
        var builder = PacketBuilder()
        builder.writeUInt8(0x42)
        
        let data = builder.build()
        XCTAssertEqual(data, Data([0x42]))
    }
    
    func testWriteUInt16() {
        var builder = PacketBuilder()
        builder.writeUInt16(0x1234)
        
        let data = builder.build()
        XCTAssertEqual(data, Data([0x12, 0x34]))
    }
    
    func testWriteUInt32() {
        var builder = PacketBuilder()
        builder.writeUInt32(0x12345678)
        
        let data = builder.build()
        XCTAssertEqual(data, Data([0x12, 0x34, 0x56, 0x78]))
    }
    
    func testWriteVariableInt1Byte() {
        var builder = PacketBuilder()
        builder.writeVariableInt(37)
        
        let data = builder.build()
        XCTAssertEqual(data, Data([0x25]))
    }
    
    func testWriteVariableInt2Bytes() {
        var builder = PacketBuilder()
        builder.writeVariableInt(15293)
        
        let data = builder.build()
        XCTAssertEqual(data, Data([0x7B, 0xBD]))
    }
    
    func testWriteBytes() {
        var builder = PacketBuilder()
        builder.writeBytes(Data([0x01, 0x02, 0x03]))
        
        let data = builder.build()
        XCTAssertEqual(data, Data([0x01, 0x02, 0x03]))
    }
    
    func testWritePacketNumber() {
        var builder = PacketBuilder()
        builder.writePacketNumber(0x12345678, length: 3)
        
        let data = builder.build()
        XCTAssertEqual(data, Data([0x34, 0x56, 0x78]))
    }
    
    func testCount() {
        var builder = PacketBuilder()
        XCTAssertEqual(builder.count, 0)
        
        builder.writeUInt8(0x01)
        XCTAssertEqual(builder.count, 1)
        
        builder.writeUInt16(0x0203)
        XCTAssertEqual(builder.count, 3)
    }
    
    func testClear() {
        var builder = PacketBuilder()
        builder.writeUInt32(0x12345678)
        XCTAssertEqual(builder.count, 4)
        
        builder.clear()
        XCTAssertEqual(builder.count, 0)
        
        let data = builder.build()
        XCTAssertEqual(data.count, 0)
    }
    
    func testRoundTripParsing() throws {
        var builder = PacketBuilder()
        builder.writeUInt8(0x42)
        builder.writeUInt16(0x1234)
        builder.writeVariableInt(494878333)
        builder.writeBytes(Data([0xAA, 0xBB]))
        
        let data = builder.build()
        var parser = PacketParser(data: data)
        
        let uint8Value = try parser.readUInt8()
        XCTAssertEqual(uint8Value, 0x42)
        
        let uint16Value = try parser.readUInt16()
        XCTAssertEqual(uint16Value, 0x1234)
        
        let varIntValue = try parser.readVariableInt()
        XCTAssertEqual(varIntValue, 494878333)
        
        let bytesValue = try parser.readBytes(count: 2)
        XCTAssertEqual(bytesValue, Data([0xAA, 0xBB]))
    }
}