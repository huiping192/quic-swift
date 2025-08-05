import Foundation
import Security

// MARK: - 版本协商
public struct VersionNegotiation {
    
    // MARK: - 版本协商包创建
    public static func createVersionNegotiationPacket(
        destinationConnectionID: ConnectionID,
        sourceConnectionID: ConnectionID
    ) -> Data {
        var builder = PacketBuilder()
        
        // 长包头，版本协商包
        var firstByte: UInt8 = 0x80 // Header Form = 1
        firstByte |= 0x40          // Fixed Bit = 1
        // Type字段对版本协商包无意义，保持为0
        
        builder.writeUInt8(firstByte)
        
        // 版本字段设为0表示版本协商
        builder.writeUInt32(QUICVersion.negotiation)
        
        // 连接ID长度
        let lengths = (destinationConnectionID.length << 4) | sourceConnectionID.length
        builder.writeUInt8(lengths)
        
        // 连接IDs
        builder.writeBytes(destinationConnectionID.bytes)
        builder.writeBytes(sourceConnectionID.bytes)
        
        // 支持的版本列表
        for version in QUICVersion.supportedVersions {
            builder.writeUInt32(version)
        }
        
        return builder.build()
    }
    
    // MARK: - 版本选择
    public static func selectVersion(from clientVersions: [UInt32]) -> UInt32? {
        // 按优先级顺序查找第一个匹配的版本
        for supportedVersion in QUICVersion.supportedVersions {
            if clientVersions.contains(supportedVersion) {
                return supportedVersion
            }
        }
        return nil
    }
    
    // MARK: - 从版本协商包中提取版本列表
    public static func extractVersionsFromNegotiationPacket(_ packet: QUICPacket) throws -> [UInt32] {
        guard packet.version == QUICVersion.negotiation else {
            throw QUICError.protocolViolation("Not a version negotiation packet")
        }
        
        let payload = packet.payload
        guard payload.count % 4 == 0 else {
            throw QUICError.malformedPacket("Version negotiation payload length not multiple of 4")
        }
        
        var versions: [UInt32] = []
        var parser = PacketParser(data: payload)
        
        while parser.hasMoreData {
            let version = try parser.readUInt32()
            versions.append(version)
        }
        
        return versions
    }
    
    // MARK: - 版本兼容性检查
    public static func isVersionSupported(_ version: UInt32) -> Bool {
        return QUICVersion.supportedVersions.contains(version)
    }
    
    // MARK: - 版本协商需求检查
    public static func requiresVersionNegotiation(clientVersion: UInt32) -> Bool {
        return !isVersionSupported(clientVersion) && clientVersion != QUICVersion.negotiation
    }
}

// MARK: - 版本协商状态机
public class VersionNegotiationStateMachine {
    public enum State {
        case initial
        case negotiationSent
        case negotiationReceived([UInt32])
        case versionSelected(UInt32)
        case failed(Error)
    }
    
    private var _state: State = .initial
    private let stateQueue = DispatchQueue(label: "version.negotiation", qos: .userInitiated)
    
    public var state: State {
        return stateQueue.sync { _state }
    }
    
    public var onStateChange: ((State, State) -> Void)?
    
    // MARK: - 客户端版本协商
    public func handleVersionNegotiationAsClient(packet: QUICPacket) -> Result<UInt32, Error> {
        return stateQueue.sync {
            do {
                let serverVersions = try VersionNegotiation.extractVersionsFromNegotiationPacket(packet)
                let oldState = _state
                _state = .negotiationReceived(serverVersions)
                onStateChange?(oldState, _state)
                
                if let selectedVersion = VersionNegotiation.selectVersion(from: serverVersions) {
                    let newState = State.versionSelected(selectedVersion)
                    onStateChange?(_state, newState)
                    _state = newState
                    return .success(selectedVersion)
                } else {
                    let error = QUICError.unsupportedVersion(0)
                    let failedState = State.failed(error)
                    onStateChange?(_state, failedState)
                    _state = failedState
                    return .failure(error)
                }
            } catch {
                let failedState = State.failed(error)
                onStateChange?(_state, failedState)
                _state = failedState
                return .failure(error)
            }
        }
    }
    
    // MARK: - 服务端版本协商
    public func handleVersionNegotiationAsServer(clientVersion: UInt32) -> Result<(Bool, Data?), Error> {
        return stateQueue.sync {
            if VersionNegotiation.isVersionSupported(clientVersion) {
                // 版本支持，无需协商
                let oldState = _state
                _state = .versionSelected(clientVersion)
                onStateChange?(oldState, _state)
                return .success((false, nil))
            } else {
                // 需要版本协商
                let oldState = _state
                _state = .negotiationSent
                onStateChange?(oldState, _state)
                
                // 创建版本协商包需要连接ID，这里返回需要协商的标志
                return .success((true, nil))
            }
        }
    }
    
    public func reset() {
        stateQueue.sync {
            let oldState = _state
            _state = .initial
            onStateChange?(oldState, _state)
        }
    }
}

// MARK: - 版本协商辅助工具
public struct VersionNegotiationHelper {
    
    // MARK: - 创建Initial包用于版本协商后重试
    public static func createRetryInitialPacket(
        selectedVersion: UInt32,
        destinationConnectionID: ConnectionID,
        sourceConnectionID: ConnectionID,
        payload: Data
    ) -> Data {
        var builder = PacketBuilder()
        
        // 构造Initial包头
        var firstByte: UInt8 = 0x80 // Header Form = 1
        firstByte |= 0x40          // Fixed Bit = 1
        firstByte |= (QUICPacketType.initial.rawValue & 0x03) << 4 // Type = Initial
        firstByte |= 0x03          // Packet Number Length = 4 bytes
        
        builder.writeUInt8(firstByte)
        builder.writeUInt32(selectedVersion)
        
        // 连接ID长度
        let lengths = (destinationConnectionID.length << 4) | sourceConnectionID.length
        builder.writeUInt8(lengths)
        
        // 连接IDs
        builder.writeBytes(destinationConnectionID.bytes)
        builder.writeBytes(sourceConnectionID.bytes)
        
        // Token字段（空）
        builder.writeVariableInt(0)
        
        // 长度字段（包号4字节 + 载荷长度）
        let totalLength = 4 + payload.count
        builder.writeVariableInt(UInt64(totalLength))
        
        // 包号（重新开始）
        builder.writePacketNumber(0, length: 4)
        
        // 载荷
        builder.writeBytes(payload)
        
        return builder.build()
    }
    
    // MARK: - 验证版本协商包的有效性
    public static func validateVersionNegotiationPacket(_ packet: QUICPacket) -> Result<Void, Error> {
        // 检查是否为版本协商包
        guard packet.version == QUICVersion.negotiation else {
            return .failure(QUICError.protocolViolation("Not a version negotiation packet"))
        }
        
        // 检查包头形式
        guard packet.headerForm == .long else {
            return .failure(QUICError.protocolViolation("Version negotiation must use long header"))
        }
        
        // 检查载荷长度
        guard packet.payload.count % 4 == 0 && packet.payload.count > 0 else {
            return .failure(QUICError.malformedPacket("Invalid version list in negotiation packet"))
        }
        
        // 验证版本列表不为空
        do {
            let versions = try VersionNegotiation.extractVersionsFromNegotiationPacket(packet)
            guard !versions.isEmpty else {
                return .failure(QUICError.malformedPacket("Empty version list in negotiation packet"))
            }
        } catch {
            return .failure(error)
        }
        
        return .success(())
    }
    
    // MARK: - 生成新的连接ID用于版本协商后的连接
    public static func generateNewConnectionIDAfterNegotiation() -> ConnectionID {
        let length = UInt8.random(in: 8...20)
        var bytes = Data(count: Int(length))
        bytes.withUnsafeMutableBytes { bufferPointer in
            _ = SecRandomCopyBytes(kSecRandomDefault, Int(length), bufferPointer.baseAddress!)
        }
        return ConnectionID(bytes: bytes, length: length)
    }
}

// MARK: - 版本协商错误扩展
extension QUICError {
    public static func versionNegotiationFailed(clientVersions: [UInt32], serverVersions: [UInt32]) -> QUICError {
        let message = "Version negotiation failed: client=[\(clientVersions.map { $0.hexString }.joined(separator: ","))], server=[\(serverVersions.map { $0.hexString }.joined(separator: ","))]"
        return .protocolViolation(message)
    }
}