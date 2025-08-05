import Foundation

public struct PacketParser {
    private let data: Data
    private var offset: Int = 0
    
    public init(data: Data) {
        self.data = data
    }
    
    public mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw ParsingError.insufficientData
        }
        let value = data[offset]
        offset += 1
        return value
    }
    
    public mutating func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw ParsingError.insufficientData
        }
        let value = data.subdata(in: offset..<offset+2).withUnsafeBytes {
            $0.load(as: UInt16.self).bigEndian
        }
        offset += 2
        return value
    }
    
    public mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw ParsingError.insufficientData
        }
        let value = data.subdata(in: offset..<offset+4).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        offset += 4
        return value
    }
    
    public mutating func readUInt64() throws -> UInt64 {
        guard offset + 8 <= data.count else {
            throw ParsingError.insufficientData
        }
        let value = data.subdata(in: offset..<offset+8).withUnsafeBytes {
            $0.load(as: UInt64.self).bigEndian
        }
        offset += 8
        return value
    }
    
    public mutating func readVariableInt() throws -> UInt64 {
        let firstByte = try readUInt8()
        let lengthBits = (firstByte & 0xC0) >> 6
        
        switch lengthBits {
        case 0: 
            return UInt64(firstByte & 0x3F)
        case 1:
            let secondByte = try readUInt8()
            return UInt64((firstByte & 0x3F)) << 8 | UInt64(secondByte)
        case 2:
            let bytes = try readBytes(count: 3)
            var value: UInt32 = 0
            for byte in bytes {
                value = (value << 8) | UInt32(byte)
            }
            return UInt64((firstByte & 0x3F)) << 24 | UInt64(value)
        case 3:
            let bytes = try readBytes(count: 7)
            var value: UInt64 = 0
            for byte in bytes {
                value = (value << 8) | UInt64(byte)
            }
            return UInt64((firstByte & 0x3F)) << 56 | value
        default:
            throw ParsingError.invalidVariableInt
        }
    }
    
    public mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0 else {
            throw ParsingError.invalidOffset
        }
        
        guard offset + count <= data.count else {
            throw ParsingError.insufficientData
        }
        
        let result = data.subdata(in: offset..<offset+count)
        offset += count
        return result
    }
    
    public mutating func readPacketNumber(length: Int) throws -> UInt64 {
        guard length > 0 && length <= 4 else {
            throw ParsingError.invalidOffset
        }
        
        let bytes = try readBytes(count: length)
        var packetNumber: UInt64 = 0
        
        for byte in bytes {
            packetNumber = (packetNumber << 8) | UInt64(byte)
        }
        
        return packetNumber
    }
    
    public var hasMoreData: Bool {
        return offset < data.count
    }
    
    public var remainingBytes: Int {
        return data.count - offset
    }
    
    public var currentOffset: Int {
        return offset
    }
    
    public mutating func skip(bytes: Int) throws {
        guard bytes >= 0 else {
            throw ParsingError.invalidOffset
        }
        
        guard offset + bytes <= data.count else {
            throw ParsingError.insufficientData
        }
        
        offset += bytes
    }
    
    public mutating func reset() {
        offset = 0
    }
    
    public func peek(at index: Int) throws -> UInt8 {
        guard index >= 0 && index < data.count else {
            throw ParsingError.invalidOffset
        }
        return data[index]
    }
}

public struct PacketBuilder {
    private var data = Data()
    
    public init() {}
    
    public mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }
    
    public mutating func writeUInt16(_ value: UInt16) {
        let bigEndianValue = value.bigEndian
        withUnsafeBytes(of: bigEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }
    
    public mutating func writeUInt32(_ value: UInt32) {
        let bigEndianValue = value.bigEndian
        withUnsafeBytes(of: bigEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }
    
    public mutating func writeUInt64(_ value: UInt64) {
        let bigEndianValue = value.bigEndian
        withUnsafeBytes(of: bigEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }
    
    public mutating func writeVariableInt(_ value: UInt64) {
        if value < 64 {
            writeUInt8(UInt8(value))
        } else if value < 16384 {
            let encodedValue = 0x4000 | value
            writeUInt16(UInt16(encodedValue))
        } else if value < 1073741824 {
            let encodedValue = 0x80000000 | value
            writeUInt32(UInt32(encodedValue))
        } else {
            let encodedValue = 0xC000000000000000 | value
            writeUInt64(encodedValue)
        }
    }
    
    public mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }
    
    public mutating func writePacketNumber(_ packetNumber: UInt64, length: Int) {
        let bytes = withUnsafeBytes(of: packetNumber.bigEndian) { Array($0) }
        let startIndex = 8 - length
        data.append(contentsOf: bytes[startIndex...])
    }
    
    public func build() -> Data {
        return data
    }
    
    public var count: Int {
        return data.count
    }
    
    public mutating func clear() {
        data.removeAll()
    }
}