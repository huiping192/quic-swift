import Foundation

// MARK: - 流帧类型
public enum StreamFrameType: UInt8 {
    case stream = 0x08          // 0b00001000
    case resetStream = 0x04     // 0b00000100
    case stopSending = 0x05     // 0b00000101
    case maxStreamData = 0x11   // 0b00010001
    case streamDataBlocked = 0x15 // 0b00010101
    case maxStreams = 0x12      // 0b00010010 (bidirectional)
    case streamsBlocked = 0x16  // 0b00010110 (bidirectional)
}

// MARK: - STREAM帧
public struct StreamFrame {
    public let streamID: UInt64
    public let offset: UInt64
    public let data: Data
    public let fin: Bool
    public let length: UInt64?
    
    public init(streamID: UInt64, offset: UInt64, data: Data, fin: Bool = false, length: UInt64? = nil) {
        self.streamID = streamID
        self.offset = offset
        self.data = data
        self.fin = fin
        self.length = length ?? UInt64(data.count)
    }
    
    // MARK: - 解析
    public static func parse(from data: Data) throws -> StreamFrame {
        guard !data.isEmpty else {
            throw StreamError.frameTooLarge
        }
        
        var parser = PacketParser(data: data)
        
        // 解析帧类型和标志
        let firstByte = try parser.readUInt8()
        let frameType = firstByte & 0xF8 // 取高5位
        
        guard frameType == StreamFrameType.stream.rawValue else {
            throw QUICError.unsupportedFrameType
        }
        
        let fin = (firstByte & 0x01) != 0
        let len = (firstByte & 0x02) != 0
        let off = (firstByte & 0x04) != 0
        
        // 解析流ID
        let streamID = try parser.readVariableInt()
        
        // 解析偏移量（如果存在）
        let offset = off ? try parser.readVariableInt() : 0
        
        // 解析长度（如果存在）
        let length = len ? try parser.readVariableInt() : nil
        
        // 解析数据
        let dataLength: Int
        if let explicitLength = length {
            dataLength = Int(explicitLength)
        } else {
            dataLength = parser.remainingBytes
        }
        
        guard dataLength >= 0 && dataLength <= parser.remainingBytes else {
            throw StreamError.frameTooLarge
        }
        
        let frameData = try parser.readBytes(count: dataLength)
        
        return StreamFrame(
            streamID: streamID,
            offset: offset,
            data: frameData,
            fin: fin,
            length: length
        )
    }
    
    // MARK: - 序列化
    public func serialize() -> Data {
        var builder = PacketBuilder()
        
        // 构造帧类型字节
        var firstByte: UInt8 = StreamFrameType.stream.rawValue
        if fin { firstByte |= 0x01 }
        if length != nil { firstByte |= 0x02 }
        if offset > 0 { firstByte |= 0x04 }
        
        builder.writeUInt8(firstByte)
        builder.writeVariableInt(streamID)
        
        if offset > 0 {
            builder.writeVariableInt(offset)
        }
        
        if let explicitLength = length {
            builder.writeVariableInt(explicitLength)
        }
        
        builder.writeBytes(data)
        
        return builder.build()
    }
    
    public var debugDescription: String {
        return "STREAM(id=\(streamID), offset=\(offset), len=\(data.count), fin=\(fin))"
    }
}

// MARK: - RESET_STREAM帧
public struct ResetStreamFrame {
    public let streamID: UInt64
    public let errorCode: UInt64
    public let finalSize: UInt64
    
    public init(streamID: UInt64, errorCode: UInt64, finalSize: UInt64) {
        self.streamID = streamID
        self.errorCode = errorCode
        self.finalSize = finalSize
    }
    
    public static func parse(from data: Data) throws -> ResetStreamFrame {
        var parser = PacketParser(data: data)
        
        let frameType = try parser.readUInt8()
        guard frameType == StreamFrameType.resetStream.rawValue else {
            throw QUICError.unsupportedFrameType
        }
        
        let streamID = try parser.readVariableInt()
        let errorCode = try parser.readVariableInt()
        let finalSize = try parser.readVariableInt()
        
        return ResetStreamFrame(
            streamID: streamID,
            errorCode: errorCode,
            finalSize: finalSize
        )
    }
    
    public func serialize() -> Data {
        var builder = PacketBuilder()
        
        builder.writeUInt8(StreamFrameType.resetStream.rawValue)
        builder.writeVariableInt(streamID)
        builder.writeVariableInt(errorCode)
        builder.writeVariableInt(finalSize)
        
        return builder.build()
    }
    
    public var debugDescription: String {
        return "RESET_STREAM(id=\(streamID), error=\(errorCode), final_size=\(finalSize))"
    }
}

// MARK: - STOP_SENDING帧
public struct StopSendingFrame {
    public let streamID: UInt64
    public let errorCode: UInt64
    
    public init(streamID: UInt64, errorCode: UInt64) {
        self.streamID = streamID
        self.errorCode = errorCode
    }
    
    public static func parse(from data: Data) throws -> StopSendingFrame {
        var parser = PacketParser(data: data)
        
        let frameType = try parser.readUInt8()
        guard frameType == StreamFrameType.stopSending.rawValue else {
            throw QUICError.unsupportedFrameType
        }
        
        let streamID = try parser.readVariableInt()
        let errorCode = try parser.readVariableInt()
        
        return StopSendingFrame(streamID: streamID, errorCode: errorCode)
    }
    
    public func serialize() -> Data {
        var builder = PacketBuilder()
        
        builder.writeUInt8(StreamFrameType.stopSending.rawValue)
        builder.writeVariableInt(streamID)
        builder.writeVariableInt(errorCode)
        
        return builder.build()
    }
    
    public var debugDescription: String {
        return "STOP_SENDING(id=\(streamID), error=\(errorCode))"
    }
}

// MARK: - MAX_STREAM_DATA帧
public struct MaxStreamDataFrame {
    public let streamID: UInt64
    public let maxStreamData: UInt64
    
    public init(streamID: UInt64, maxStreamData: UInt64) {
        self.streamID = streamID
        self.maxStreamData = maxStreamData
    }
    
    public static func parse(from data: Data) throws -> MaxStreamDataFrame {
        var parser = PacketParser(data: data)
        
        let frameType = try parser.readUInt8()
        guard frameType == StreamFrameType.maxStreamData.rawValue else {
            throw QUICError.unsupportedFrameType
        }
        
        let streamID = try parser.readVariableInt()
        let maxStreamData = try parser.readVariableInt()
        
        return MaxStreamDataFrame(streamID: streamID, maxStreamData: maxStreamData)
    }
    
    public func serialize() -> Data {
        var builder = PacketBuilder()
        
        builder.writeUInt8(StreamFrameType.maxStreamData.rawValue)
        builder.writeVariableInt(streamID)
        builder.writeVariableInt(maxStreamData)
        
        return builder.build()
    }
    
    public var debugDescription: String {
        return "MAX_STREAM_DATA(id=\(streamID), max=\(maxStreamData))"
    }
}

// MARK: - STREAM_DATA_BLOCKED帧
public struct StreamDataBlockedFrame {
    public let streamID: UInt64
    public let streamDataLimit: UInt64
    
    public init(streamID: UInt64, streamDataLimit: UInt64) {
        self.streamID = streamID
        self.streamDataLimit = streamDataLimit
    }
    
    public static func parse(from data: Data) throws -> StreamDataBlockedFrame {
        var parser = PacketParser(data: data)
        
        let frameType = try parser.readUInt8()
        guard frameType == StreamFrameType.streamDataBlocked.rawValue else {
            throw QUICError.unsupportedFrameType
        }
        
        let streamID = try parser.readVariableInt()
        let streamDataLimit = try parser.readVariableInt()
        
        return StreamDataBlockedFrame(streamID: streamID, streamDataLimit: streamDataLimit)
    }
    
    public func serialize() -> Data {
        var builder = PacketBuilder()
        
        builder.writeUInt8(StreamFrameType.streamDataBlocked.rawValue)
        builder.writeVariableInt(streamID)
        builder.writeVariableInt(streamDataLimit)
        
        return builder.build()
    }
    
    public var debugDescription: String {
        return "STREAM_DATA_BLOCKED(id=\(streamID), limit=\(streamDataLimit))"
    }
}

// MARK: - MAX_STREAMS帧
public struct MaxStreamsFrame {
    public let maxStreams: UInt64
    public let bidirectional: Bool
    
    public init(maxStreams: UInt64, bidirectional: Bool = true) {
        self.maxStreams = maxStreams
        self.bidirectional = bidirectional
    }
    
    public static func parse(from data: Data) throws -> MaxStreamsFrame {
        var parser = PacketParser(data: data)
        
        let frameType = try parser.readUInt8()
        let bidirectional = frameType == StreamFrameType.maxStreams.rawValue
        
        guard bidirectional || frameType == (StreamFrameType.maxStreams.rawValue | 0x01) else {
            throw QUICError.unsupportedFrameType
        }
        
        let maxStreams = try parser.readVariableInt()
        
        return MaxStreamsFrame(maxStreams: maxStreams, bidirectional: bidirectional)
    }
    
    public func serialize() -> Data {
        var builder = PacketBuilder()
        
        let frameType = bidirectional ? 
            StreamFrameType.maxStreams.rawValue : 
            (StreamFrameType.maxStreams.rawValue | 0x01)
        
        builder.writeUInt8(frameType)
        builder.writeVariableInt(maxStreams)
        
        return builder.build()
    }
    
    public var debugDescription: String {
        let direction = bidirectional ? "bidi" : "uni"
        return "MAX_STREAMS(\(direction), max=\(maxStreams))"
    }
}

// MARK: - STREAMS_BLOCKED帧
public struct StreamsBlockedFrame {
    public let streamLimit: UInt64
    public let bidirectional: Bool
    
    public init(streamLimit: UInt64, bidirectional: Bool = true) {
        self.streamLimit = streamLimit
        self.bidirectional = bidirectional
    }
    
    public static func parse(from data: Data) throws -> StreamsBlockedFrame {
        var parser = PacketParser(data: data)
        
        let frameType = try parser.readUInt8()
        let bidirectional = frameType == StreamFrameType.streamsBlocked.rawValue
        
        guard bidirectional || frameType == (StreamFrameType.streamsBlocked.rawValue | 0x01) else {
            throw QUICError.unsupportedFrameType
        }
        
        let streamLimit = try parser.readVariableInt()
        
        return StreamsBlockedFrame(streamLimit: streamLimit, bidirectional: bidirectional)
    }
    
    public func serialize() -> Data {
        var builder = PacketBuilder()
        
        let frameType = bidirectional ? 
            StreamFrameType.streamsBlocked.rawValue : 
            (StreamFrameType.streamsBlocked.rawValue | 0x01)
        
        builder.writeUInt8(frameType)
        builder.writeVariableInt(streamLimit)
        
        return builder.build()
    }
    
    public var debugDescription: String {
        let direction = bidirectional ? "bidi" : "uni"
        return "STREAMS_BLOCKED(\(direction), limit=\(streamLimit))"
    }
}

// MARK: - 通用流帧解析器
public struct StreamFrameParser {
    public static func parseFrame(from data: Data) throws -> Any {
        guard !data.isEmpty else {
            throw StreamError.frameTooLarge
        }
        
        let frameType = data[0]
        
        switch frameType & 0xF8 {
        case StreamFrameType.stream.rawValue:
            return try StreamFrame.parse(from: data)
        case StreamFrameType.resetStream.rawValue:
            return try ResetStreamFrame.parse(from: data)
        case StreamFrameType.stopSending.rawValue:
            return try StopSendingFrame.parse(from: data)
        case StreamFrameType.maxStreamData.rawValue:
            return try MaxStreamDataFrame.parse(from: data)
        case StreamFrameType.streamDataBlocked.rawValue:
            return try StreamDataBlockedFrame.parse(from: data)
        case StreamFrameType.maxStreams.rawValue, StreamFrameType.maxStreams.rawValue | 0x01:
            return try MaxStreamsFrame.parse(from: data)
        case StreamFrameType.streamsBlocked.rawValue, StreamFrameType.streamsBlocked.rawValue | 0x01:
            return try StreamsBlockedFrame.parse(from: data)
        default:
            throw QUICError.unsupportedFrameType
        }
    }
    
    public static func isStreamFrame(_ frameType: UInt8) -> Bool {
        let maskedType = frameType & 0xF8
        return maskedType == StreamFrameType.stream.rawValue
    }
    
    public static func isStreamControlFrame(_ frameType: UInt8) -> Bool {
        switch frameType {
        case StreamFrameType.resetStream.rawValue,
             StreamFrameType.stopSending.rawValue,
             StreamFrameType.maxStreamData.rawValue,
             StreamFrameType.streamDataBlocked.rawValue:
            return true
        case StreamFrameType.maxStreams.rawValue, StreamFrameType.maxStreams.rawValue | 0x01:
            return true
        case StreamFrameType.streamsBlocked.rawValue, StreamFrameType.streamsBlocked.rawValue | 0x01:
            return true
        default:
            return false
        }
    }
}