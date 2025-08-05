import Foundation

// MARK: - QUIC版本定义
public struct QUICVersion {
    public static let current: UInt32 = 0x00000001  // RFC 9000
    public static let draft29: UInt32 = 0xff00001d  // Draft 29  
    public static let negotiation: UInt32 = 0x00000000  // 版本协商
    
    public static let supportedVersions: [UInt32] = [
        current
        // 可以添加其他支持的版本
    ]
}

// MARK: - QUIC包类型
public enum QUICPacketType: UInt8, CaseIterable {
    case initial = 0x00        // 初始握手包
    case zeroRTT = 0x01        // 0-RTT数据包  
    case handshake = 0x02      // 握手包
    case retry = 0x03          // 重试包
    
    public var debugDescription: String {
        switch self {
        case .initial: return "Initial"
        case .zeroRTT: return "0-RTT"
        case .handshake: return "Handshake"
        case .retry: return "Retry"
        }
    }
}

// MARK: - 包头形式
public enum HeaderForm {
    case long    // 长包头（握手阶段）
    case short   // 短包头（数据传输阶段）
    
    public var debugDescription: String {
        switch self {
        case .long: return "Long Header"
        case .short: return "Short Header"
        }
    }
}

// MARK: - 连接ID
public struct ConnectionID: Hashable, CustomDebugStringConvertible {
    public let bytes: Data
    public let length: UInt8
    
    // 连接ID长度范围：0-20字节
    public static let maxLength: UInt8 = 20
    public static let minLength: UInt8 = 0
    
    public init(bytes: Data, length: UInt8) {
        precondition(length <= Self.maxLength, "Connection ID length exceeds maximum")
        precondition(UInt8(bytes.count) == length, "Bytes count doesn't match specified length")
        
        self.bytes = bytes
        self.length = length
    }
    
    public init(bytes: Data) {
        self.init(bytes: bytes, length: UInt8(bytes.count))
    }
    
    // 创建空连接ID
    public static let empty = ConnectionID(bytes: Data(), length: 0)
    
    public var isEmpty: Bool {
        return length == 0
    }
    
    public var debugDescription: String {
        if isEmpty {
            return "Empty CID"
        }
        return "CID(\(length)): \(bytes.map { String(format: "%02x", $0) }.joined())"
    }
    
    // Hashable conformance
    public func hash(into hasher: inout Hasher) {
        hasher.combine(bytes)
        hasher.combine(length)
    }
    
    public static func == (lhs: ConnectionID, rhs: ConnectionID) -> Bool {
        return lhs.bytes == rhs.bytes && lhs.length == rhs.length
    }
}

// MARK: - 握手状态
public enum HandshakeState: Equatable {
    case idle
    case clientInitial      // 客户端发送Initial
    case serverInitial      // 服务端响应Initial  
    case clientHandshake    // 客户端握手阶段
    case serverHandshake    // 服务端握手阶段
    case completed          // 握手完成
    case failed(Error)      // 握手失败
    
    public static func == (lhs: HandshakeState, rhs: HandshakeState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.clientInitial, .clientInitial),
             (.serverInitial, .serverInitial),
             (.clientHandshake, .clientHandshake),
             (.serverHandshake, .serverHandshake),
             (.completed, .completed):
            return true
        case (.failed, .failed):
            return true
        default:
            return false
        }
    }
    
    public var debugDescription: String {
        switch self {
        case .idle: return "Idle"
        case .clientInitial: return "Client Initial"
        case .serverInitial: return "Server Initial"
        case .clientHandshake: return "Client Handshake"
        case .serverHandshake: return "Server Handshake"
        case .completed: return "Completed"
        case .failed(let error): return "Failed: \(error)"
        }
    }
}

// MARK: - 包号空间
public enum PacketNumberSpace: CaseIterable {
    case initial      // Initial包使用
    case handshake    // Handshake包使用
    case application  // 1-RTT数据包使用
    
    public var debugDescription: String {
        switch self {
        case .initial: return "Initial"
        case .handshake: return "Handshake"
        case .application: return "Application"
        }
    }
}

// MARK: - QUIC错误类型
public enum QUICError: Error, LocalizedError, Equatable {
    case invalidFixedBit
    case unsupportedPacketType
    case unsupportedVersion(UInt32)
    case invalidConnectionID
    case invalidPacketNumber
    case malformedPacket(String)
    case versionNegotiationRequired
    case connectionIDCollision
    case handshakeTimeout
    case protocolViolation(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidFixedBit:
            return "Invalid fixed bit in QUIC packet header"
        case .unsupportedPacketType:
            return "Unsupported QUIC packet type"
        case .unsupportedVersion(let version):
            return "Unsupported QUIC version: 0x\(String(version, radix: 16))"
        case .invalidConnectionID:
            return "Invalid connection ID"
        case .invalidPacketNumber:
            return "Invalid packet number"
        case .malformedPacket(let reason):
            return "Malformed QUIC packet: \(reason)"
        case .versionNegotiationRequired:
            return "Version negotiation required"
        case .connectionIDCollision:
            return "Connection ID collision detected"
        case .handshakeTimeout:
            return "Handshake timeout"
        case .protocolViolation(let reason):
            return "QUIC protocol violation: \(reason)"
        }
    }
}

// MARK: - 弱引用包装器
public class WeakReference<T: AnyObject> {
    public weak var value: T?
    
    public init(_ value: T) {
        self.value = value
    }
}

// MARK: - 扩展工具
extension UInt32 {
    public var hexString: String {
        return String(format: "0x%08x", self)
    }
}

extension Data {
    public var hexString: String {
        return map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

// MARK: - 包号空间状态
public struct PacketSpaceState {
    public var nextPacketNumber: UInt64 = 0
    public var largestReceived: UInt64?
    public var receivedPackets: Set<UInt64> = []
    public var maxReceived: UInt64 = 0
    
    public init() {}
    
    public mutating func generateNextPacketNumber() -> UInt64 {
        let pn = nextPacketNumber
        nextPacketNumber += 1
        return pn
    }
    
    public mutating func markReceived(_ packetNumber: UInt64) -> Bool {
        let wasNew = !receivedPackets.contains(packetNumber)
        if wasNew {
            receivedPackets.insert(packetNumber)
            if largestReceived == nil || packetNumber > largestReceived! {
                largestReceived = packetNumber
            }
            maxReceived = max(maxReceived, packetNumber)
        }
        return wasNew
    }
    
    public func isValidPacketNumber(_ packetNumber: UInt64) -> Bool {
        // 简化的包号验证逻辑
        return !receivedPackets.contains(packetNumber)
    }
}