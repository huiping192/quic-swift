import Foundation

// MARK: - QUIC包结构
public struct QUICPacket: CustomDebugStringConvertible {
    public let headerForm: HeaderForm
    public let packetType: QUICPacketType?
    public let version: UInt32?
    public let destinationConnectionID: ConnectionID
    public let sourceConnectionID: ConnectionID?
    public let packetNumber: UInt64
    public let payload: Data
    public let token: Data?  // Initial包的token字段
    
    public init(
        headerForm: HeaderForm,
        packetType: QUICPacketType?,
        version: UInt32?,
        destinationConnectionID: ConnectionID,
        sourceConnectionID: ConnectionID?,
        packetNumber: UInt64,
        payload: Data,
        token: Data? = nil
    ) {
        self.headerForm = headerForm
        self.packetType = packetType
        self.version = version
        self.destinationConnectionID = destinationConnectionID
        self.sourceConnectionID = sourceConnectionID
        self.packetNumber = packetNumber
        self.payload = payload
        self.token = token
    }
    
    public var debugDescription: String {
        var desc = "QUIC Packet\n"
        desc += "  Header Form: \(headerForm.debugDescription)\n"
        desc += "  Type: \(packetType?.debugDescription ?? "N/A")\n"
        desc += "  Version: \(version?.hexString ?? "N/A")\n"
        desc += "  Dest CID: \(destinationConnectionID.debugDescription)\n"
        desc += "  Src CID: \(sourceConnectionID?.debugDescription ?? "N/A")\n"
        desc += "  Packet Number: \(packetNumber)\n"
        desc += "  Payload Length: \(payload.count)\n"
        if let token = token, !token.isEmpty {
            desc += "  Token Length: \(token.count)\n"
        }
        return desc
    }
}

// MARK: - QUIC包解析器
extension QUICPacket {
    public static func parse(from data: Data) throws -> QUICPacket {
        guard !data.isEmpty else {
            throw QUICError.malformedPacket("Empty packet data")
        }
        
        var parser = PacketParser(data: data)
        
        let firstByte = try parser.readUInt8()
        let headerForm: HeaderForm = (firstByte & 0x80) != 0 ? .long : .short
        
        switch headerForm {
        case .long:
            return try parseLongHeader(parser: &parser, firstByte: firstByte)
        case .short:
            return try parseShortHeader(parser: &parser, firstByte: firstByte)
        }
    }
    
    private static func parseLongHeader(parser: inout PacketParser, firstByte: UInt8) throws -> QUICPacket {
        // 验证Fixed Bit
        guard (firstByte & 0x40) != 0 else {
            throw QUICError.invalidFixedBit
        }
        
        // 提取包类型 (bits 4-5)
        let typeValue = (firstByte & 0x30) >> 4
        guard let packetType = QUICPacketType(rawValue: typeValue) else {
            throw QUICError.unsupportedPacketType
        }
        
        // 读取版本
        let version = try parser.readUInt32()
        
        // 版本协商包的特殊处理
        if version == QUICVersion.negotiation {
            return try parseVersionNegotiationPacket(parser: &parser, firstByte: firstByte)
        }
        
        // 验证版本支持
        guard QUICVersion.supportedVersions.contains(version) else {
            throw QUICError.unsupportedVersion(version)
        }
        
        // 读取连接ID长度字节
        let connectionIDLengths = try parser.readUInt8()
        let destLength = (connectionIDLengths & 0xF0) >> 4
        let srcLength = connectionIDLengths & 0x0F
        
        // 验证连接ID长度
        guard destLength <= ConnectionID.maxLength && srcLength <= ConnectionID.maxLength else {
            throw QUICError.invalidConnectionID
        }
        
        // 读取目标连接ID
        let destCIDData = try parser.readBytes(count: Int(destLength))
        let destinationConnectionID = ConnectionID(bytes: destCIDData, length: destLength)
        
        // 读取源连接ID
        let sourceConnectionID: ConnectionID?
        if srcLength > 0 {
            let srcCIDData = try parser.readBytes(count: Int(srcLength))
            sourceConnectionID = ConnectionID(bytes: srcCIDData, length: srcLength)
        } else {
            sourceConnectionID = nil
        }
        
        // 根据包类型处理特定字段
        return try parsePacketTypeSpecificFields(
            parser: &parser,
            firstByte: firstByte,
            packetType: packetType,
            version: version,
            destinationConnectionID: destinationConnectionID,
            sourceConnectionID: sourceConnectionID
        )
    }
    
    private static func parsePacketTypeSpecificFields(
        parser: inout PacketParser,
        firstByte: UInt8,
        packetType: QUICPacketType,
        version: UInt32,
        destinationConnectionID: ConnectionID,
        sourceConnectionID: ConnectionID?
    ) throws -> QUICPacket {
        
        var token: Data?
        
        switch packetType {
        case .initial:
            // Initial包包含Token字段
            let tokenLength = try parser.readVariableInt()
            if tokenLength > 0 {
                token = try parser.readBytes(count: Int(tokenLength))
            }
            fallthrough
            
        case .handshake, .zeroRTT:
            // 读取剩余长度
            let length = try parser.readVariableInt()
            
            // 提取包号长度（最后2位 + 1）
            let packetNumberLength = Int((firstByte & 0x03) + 1)
            
            // 验证长度合理性
            guard length >= packetNumberLength else {
                throw QUICError.malformedPacket("Length field smaller than packet number length")
            }
            
            // 读取包号
            let packetNumber = try parser.readPacketNumber(length: packetNumberLength)
            
            // 计算载荷长度
            let payloadLength = Int(length) - packetNumberLength
            guard payloadLength >= 0 else {
                throw QUICError.malformedPacket("Invalid payload length")
            }
            
            // 读取载荷
            let payload = try parser.readBytes(count: payloadLength)
            
            return QUICPacket(
                headerForm: .long,
                packetType: packetType,
                version: version,
                destinationConnectionID: destinationConnectionID,
                sourceConnectionID: sourceConnectionID,
                packetNumber: packetNumber,
                payload: payload,
                token: token
            )
            
        case .retry:
            // Retry包的特殊处理
            let remainingBytes = parser.remainingBytes
            let payload = try parser.readBytes(count: remainingBytes)
            
            return QUICPacket(
                headerForm: .long,
                packetType: packetType,
                version: version,
                destinationConnectionID: destinationConnectionID,
                sourceConnectionID: sourceConnectionID,
                packetNumber: 0, // Retry包没有包号
                payload: payload
            )
        }
    }
    
    private static func parseShortHeader(parser: inout PacketParser, firstByte: UInt8) throws -> QUICPacket {
        // 验证Fixed Bit
        guard (firstByte & 0x40) != 0 else {
            throw QUICError.invalidFixedBit
        }
        
        // 短包头需要从外部上下文获取连接ID长度
        // 这里假设有一个固定长度，实际实现中需要从连接状态获取
        let connectionIDLength = 8 // 默认长度，实际应该从连接状态获取
        
        // 读取目标连接ID
        let destCIDData = try parser.readBytes(count: connectionIDLength)
        let destinationConnectionID = ConnectionID(bytes: destCIDData)
        
        // 提取包号长度（最后2位 + 1）
        let packetNumberLength = Int((firstByte & 0x03) + 1)
        
        // 读取包号
        let packetNumber = try parser.readPacketNumber(length: packetNumberLength)
        
        // 读取剩余数据作为载荷
        let remainingBytes = parser.remainingBytes
        let payload = try parser.readBytes(count: remainingBytes)
        
        return QUICPacket(
            headerForm: .short,
            packetType: nil, // 短包头没有显式的包类型
            version: nil,
            destinationConnectionID: destinationConnectionID,
            sourceConnectionID: nil,
            packetNumber: packetNumber,
            payload: payload
        )
    }
    
    private static func parseVersionNegotiationPacket(parser: inout PacketParser, firstByte: UInt8) throws -> QUICPacket {
        // 读取连接ID长度
        let connectionIDLengths = try parser.readUInt8()
        let destLength = (connectionIDLengths & 0xF0) >> 4
        let srcLength = connectionIDLengths & 0x0F
        
        // 读取连接IDs
        let destCIDData = try parser.readBytes(count: Int(destLength))
        let destinationConnectionID = ConnectionID(bytes: destCIDData, length: destLength)
        
        let sourceConnectionID: ConnectionID?
        if srcLength > 0 {
            let srcCIDData = try parser.readBytes(count: Int(srcLength))
            sourceConnectionID = ConnectionID(bytes: srcCIDData, length: srcLength)
        } else {
            sourceConnectionID = nil
        }
        
        // 读取支持的版本列表作为载荷
        let remainingBytes = parser.remainingBytes
        let payload = try parser.readBytes(count: remainingBytes)
        
        return QUICPacket(
            headerForm: .long,
            packetType: nil, // 版本协商包没有包类型
            version: QUICVersion.negotiation,
            destinationConnectionID: destinationConnectionID,
            sourceConnectionID: sourceConnectionID,
            packetNumber: 0, // 版本协商包没有包号
            payload: payload
        )
    }
}

// MARK: - QUIC包序列化
extension QUICPacket {
    public func serialize() -> Data {
        var builder = PacketBuilder()
        
        switch headerForm {
        case .long:
            serializeLongHeader(to: &builder)
        case .short:
            serializeShortHeader(to: &builder)
        }
        
        return builder.build()
    }
    
    private func serializeLongHeader(to builder: inout PacketBuilder) {
        // 构造第一个字节
        var firstByte: UInt8 = 0x80 // Header Form = 1
        firstByte |= 0x40 // Fixed Bit = 1
        
        if let packetType = packetType {
            firstByte |= (packetType.rawValue & 0x03) << 4 // Type字段
        }
        
        // 包号长度（暂时使用4字节）
        let packetNumberLength = 4
        firstByte |= UInt8(packetNumberLength - 1) // Packet Number Length
        
        builder.writeUInt8(firstByte)
        
        // 写入版本
        builder.writeUInt32(version ?? QUICVersion.current)
        
        // 写入连接ID长度
        let destLength = destinationConnectionID.length
        let srcLength = sourceConnectionID?.length ?? 0
        let lengths = (destLength << 4) | srcLength
        builder.writeUInt8(lengths)
        
        // 写入连接IDs
        builder.writeBytes(destinationConnectionID.bytes)
        if let sourceConnectionID = sourceConnectionID {
            builder.writeBytes(sourceConnectionID.bytes)
        }
        
        // 根据包类型写入特定字段
        if packetType == .initial {
            // Token字段
            if let token = token {
                builder.writeVariableInt(UInt64(token.count))
                builder.writeBytes(token)
            } else {
                builder.writeVariableInt(0)
            }
        }
        
        if packetType != .retry {
            // 长度字段（包号长度 + 载荷长度）
            let totalLength = packetNumberLength + payload.count
            builder.writeVariableInt(UInt64(totalLength))
            
            // 包号
            builder.writePacketNumber(packetNumber, length: packetNumberLength)
        }
        
        // 载荷
        builder.writeBytes(payload)
    }
    
    private func serializeShortHeader(to builder: inout PacketBuilder) {
        // 构造第一个字节
        var firstByte: UInt8 = 0x00 // Header Form = 0
        firstByte |= 0x40 // Fixed Bit = 1
        
        // 包号长度（暂时使用4字节）
        let packetNumberLength = 4
        firstByte |= UInt8(packetNumberLength - 1) // Packet Number Length
        
        builder.writeUInt8(firstByte)
        
        // 写入目标连接ID
        builder.writeBytes(destinationConnectionID.bytes)
        
        // 写入包号
        builder.writePacketNumber(packetNumber, length: packetNumberLength)
        
        // 写入载荷
        builder.writeBytes(payload)
    }
}