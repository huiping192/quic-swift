# 阶段二：QUIC核心概念

## 学习目标

在第一阶段的网络编程基础上，这个阶段将实现QUIC协议的核心概念：

- QUIC包格式的解析和构造
- 连接ID管理机制  
- 版本协商流程
- 基础握手流程实现
- 包号空间和加密层级
- 简化的密钥管理

## 理论知识要点

### 1. QUIC包类型和结构

QUIC定义了两种主要的包格式：

#### 长包头包（握手阶段使用）
```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
|1|1|T T|K K|P P|  <- Header Form=1, Fixed Bit=1, Type, Key Phase, PN Length
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Version (32)                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|DCIL|SCIL|     <- Destination/Source Connection ID Length
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|               Destination Connection ID (0..160)           ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Source Connection ID (0..160)              ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Length (i)                          ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Packet Number (8/16/24/32)              ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Payload (*)                       ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

#### 短包头包（数据传输阶段使用）
```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
|0|1|S|R|R|K|P P|  <- Header Form=0, Fixed Bit=1, Spin, Reserved, Key Phase, PN Length
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                Destination Connection ID (0..160)          ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Packet Number (8/16/24/32)             ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Protected Payload (*)                  ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 2. 包类型定义

```swift
enum QUICPacketType: UInt8 {
    case initial = 0x00        // 初始握手包
    case zeroRTT = 0x01        // 0-RTT数据包  
    case handshake = 0x02      // 握手包
    case retry = 0x03          // 重试包
    case shortHeader = 0xFF    // 短包头（数据传输）
}
```

### 3. 连接ID机制

连接ID是QUIC的核心创新，使连接不依赖于网络路径：

```swift
struct ConnectionID {
    let bytes: Data
    let length: UInt8
    
    // 连接ID长度范围：0-20字节
    static let maxLength: UInt8 = 20
    static let minLength: UInt8 = 0
}
```

### 4. 版本协商

QUIC支持版本协商来处理不同版本间的兼容性：

```swift
struct QUICVersion {
    static let current: UInt32 = 0x00000001  // RFC 9000
    static let draft29: UInt32 = 0xff00001d  // Draft 29
    static let negotiation: UInt32 = 0x00000000  // 版本协商
}
```

## 实现任务清单

### 任务1：QUIC包解析器

**目标**: 实现完整的QUIC包解析和构造功能

**要求**:
- [ ] 实现`QUICPacket`结构体
- [ ] 支持长包头和短包头解析
- [ ] 实现包类型识别
- [ ] 支持连接ID提取
- [ ] 实现包号解析
- [ ] 添加包验证逻辑

**核心接口**:
```swift
struct QUICPacket {
    let headerForm: HeaderForm
    let packetType: QUICPacketType?
    let version: UInt32?
    let destinationConnectionID: ConnectionID
    let sourceConnectionID: ConnectionID?
    let packetNumber: UInt64
    let payload: Data
    
    static func parse(from data: Data) throws -> QUICPacket
    func serialize() -> Data
}
```

### 任务2：连接ID管理器

**目标**: 实现连接ID的生成、管理和路由功能

**要求**:
- [ ] 实现`ConnectionIDManager`类
- [ ] 支持连接ID生成
- [ ] 实现连接ID到连接的映射
- [ ] 支持连接ID退役机制
- [ ] 添加连接ID验证
- [ ] 实现连接路由逻辑

**核心功能**:
```swift
class ConnectionIDManager {
    func generateConnectionID() -> ConnectionID
    func registerConnection(id: ConnectionID, connection: QUICConnection)
    func routePacket(_ packet: QUICPacket) -> QUICConnection?
    func retireConnectionID(_ id: ConnectionID)
    func validateConnectionID(_ id: ConnectionID) -> Bool
}
```

### 任务3：版本协商实现

**目标**: 实现QUIC版本协商机制

**要求**:
- [ ] 实现版本协商包的生成
- [ ] 支持客户端版本选择
- [ ] 实现服务端版本响应
- [ ] 添加不支持版本的处理
- [ ] 实现版本降级保护

**版本协商流程**:
```
Client                    Server
  |                         |
  |---Initial(v2)---------->| 不支持v2
  |<--Version Negotiation---| 返回支持的版本列表
  |---Initial(v1)---------->| 支持v1
  |<--Initial+Handshake-----| 继续握手
```

### 任务4：基础握手状态机

**目标**: 实现简化的QUIC握手流程

**要求**:
- [ ] 定义握手状态枚举
- [ ] 实现客户端握手逻辑
- [ ] 实现服务端握手逻辑
- [ ] 支持Initial包交换
- [ ] 实现基础的Handshake包处理
- [ ] 添加握手超时处理

**握手状态定义**:
```swift
enum HandshakeState {
    case idle
    case clientInitial      // 客户端发送Initial
    case serverInitial      // 服务端响应Initial  
    case clientHandshake    // 客户端握手阶段
    case serverHandshake    // 服务端握手阶段
    case completed          // 握手完成
    case failed(Error)      // 握手失败
}
```

### 任务5：包号空间管理

**目标**: 实现QUIC的包号空间概念

**要求**:
- [ ] 实现`PacketNumberSpace`结构
- [ ] 支持三个包号空间（Initial, Handshake, Application）
- [ ] 实现包号生成和验证
- [ ] 支持包号去重
- [ ] 添加包号范围检查

**包号空间定义**:
```swift
enum PacketNumberSpace {
    case initial      // Initial包使用
    case handshake    // Handshake包使用
    case application  // 1-RTT数据包使用
}

struct PacketNumberManager {
    private var spaces: [PacketNumberSpace: PacketSpaceState]
    
    func nextPacketNumber(for space: PacketNumberSpace) -> UInt64
    func validatePacketNumber(_ pn: UInt64, in space: PacketNumberSpace) -> Bool
    func markReceived(_ pn: UInt64, in space: PacketNumberSpace)
}
```

## 代码示例

### QUIC包解析实现

```swift
struct QUICPacket {
    enum HeaderForm {
        case long
        case short
    }
    
    let headerForm: HeaderForm
    let packetType: QUICPacketType?
    let version: UInt32?
    let destinationConnectionID: ConnectionID
    let sourceConnectionID: ConnectionID?
    let packetNumber: UInt64
    let payload: Data
    
    static func parse(from data: Data) throws -> QUICPacket {
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
        
        // 提取包类型
        let typeValue = (firstByte & 0x30) >> 4
        let packetType = QUICPacketType(rawValue: typeValue)
        
        // 读取版本
        let version = try parser.readUInt32()
        
        // 读取连接ID长度
        let connectionIDLengths = try parser.readUInt8()
        let destLength = (connectionIDLengths & 0xF0) >> 4
        let srcLength = connectionIDLengths & 0x0F
        
        // 读取目标连接ID
        let destCIDData = try parser.readBytes(count: Int(destLength))
        let destinationConnectionID = ConnectionID(bytes: destCIDData, length: destLength)
        
        // 读取源连接ID
        let srcCIDData = try parser.readBytes(count: Int(srcLength))
        let sourceConnectionID = srcLength > 0 ? ConnectionID(bytes: srcCIDData, length: srcLength) : nil
        
        // 根据包类型读取特定字段
        switch packetType {
        case .initial:
            let tokenLength = try parser.readVariableInt()
            let _ = try parser.readBytes(count: Int(tokenLength)) // Token
            fallthrough
        case .handshake, .zeroRTT:
            let length = try parser.readVariableInt()
            let packetNumberLength = ((firstByte & 0x03) + 1)
            let packetNumber = try parser.readPacketNumber(length: Int(packetNumberLength))
            let payloadLength = Int(length) - Int(packetNumberLength)
            let payload = try parser.readBytes(count: payloadLength)
            
            return QUICPacket(
                headerForm: .long,
                packetType: packetType,
                version: version,
                destinationConnectionID: destinationConnectionID,
                sourceConnectionID: sourceConnectionID,
                packetNumber: packetNumber,
                payload: payload
            )
        default:
            throw QUICError.unsupportedPacketType
        }
    }
}
```

### 连接ID管理器实现

```swift
class ConnectionIDManager {
    private var connectionMap: [ConnectionID: WeakReference<QUICConnection>] = [:]
    private var activeIDs: Set<ConnectionID> = []
    private let lock = NSLock()
    
    func generateConnectionID() -> ConnectionID {
        let length = UInt8.random(in: 8...20)
        var bytes = Data(count: Int(length))
        _ = SecRandomCopyBytes(kSecRandomDefault, Int(length), &bytes)
        return ConnectionID(bytes: bytes, length: length)
    }
    
    func registerConnection(id: ConnectionID, connection: QUICConnection) {
        lock.withLock {
            connectionMap[id] = WeakReference(connection)
            activeIDs.insert(id)
        }
    }
    
    func routePacket(_ packet: QUICPacket) -> QUICConnection? {
        lock.withLock {
            return connectionMap[packet.destinationConnectionID]?.value
        }
    }
    
    func retireConnectionID(_ id: ConnectionID) {
        lock.withLock {
            connectionMap.removeValue(forKey: id)
            activeIDs.remove(id)
        }
    }
    
    private func cleanupStaleReferences() {
        lock.withLock {
            connectionMap = connectionMap.compactMapValues { ref in
                ref.value != nil ? ref : nil
            }
        }
    }
}
```

### 版本协商实现

```swift
struct VersionNegotiation {
    static let supportedVersions: [UInt32] = [
        QUICVersion.current,
        // 可以添加其他支持的版本
    ]
    
    static func createVersionNegotiationPacket(
        destinationConnectionID: ConnectionID,
        sourceConnectionID: ConnectionID
    ) -> Data {
        var data = Data()
        
        // 长包头，版本协商包
        data.append(0x80 | 0x40)  // Header Form=1, Fixed Bit=1
        data.append(contentsOf: withUnsafeBytes(of: QUICVersion.negotiation.bigEndian) { Array($0) })
        
        // 连接ID长度
        let lengths = (destinationConnectionID.length << 4) | sourceConnectionID.length
        data.append(lengths)
        
        // 连接IDs
        data.append(destinationConnectionID.bytes)
        data.append(sourceConnectionID.bytes)
        
        // 支持的版本列表
        for version in supportedVersions {
            data.append(contentsOf: withUnsafeBytes(of: version.bigEndian) { Array($0) })
        }
        
        return data
    }
    
    static func selectVersion(from clientVersions: [UInt32]) -> UInt32? {
        for version in supportedVersions {
            if clientVersions.contains(version) {
                return version
            }
        }
        return nil
    }
}
```

## 测试验证

### 单元测试要求

- [ ] QUIC包解析和序列化测试
- [ ] 连接ID生成和验证测试
- [ ] 版本协商逻辑测试
- [ ] 包号空间管理测试
- [ ] 握手状态机测试

### 集成测试场景

- [ ] 完整的版本协商流程测试
- [ ] 基础握手流程测试
- [ ] 包路由功能测试
- [ ] 错误包处理测试
- [ ] 并发连接处理测试

### 协议一致性测试

- [ ] 与标准QUIC实现的互操作性测试
- [ ] RFC 9000合规性验证
- [ ] 边界条件处理测试

## 调试工具和方法

### 包分析工具

```swift
extension QUICPacket {
    func debugDescription() -> String {
        var desc = "QUIC Packet\\n"
        desc += "  Header Form: \\(headerForm)\\n"
        desc += "  Type: \\(packetType?.debugDescription ?? \"N/A\")\\n"
        desc += "  Version: \\(version?.hexString ?? \"N/A\")\\n"
        desc += "  Dest CID: \\(destinationConnectionID.debugDescription)\\n"
        desc += "  Src CID: \\(sourceConnectionID?.debugDescription ?? \"N/A\")\\n"
        desc += "  Packet Number: \\(packetNumber)\\n"
        desc += "  Payload Length: \\(payload.count)\\n"
        return desc
    }
}
```

### Wireshark集成

为了便于调试，建议：
- 启用QUIC包的详细日志
- 使用Wireshark捕获和分析包
- 实现包的十六进制转储功能

## 常见问题和解决方案

1. **包解析失败**: 仔细检查字节序和变长整数编码
2. **连接ID冲突**: 实现充分的随机性和碰撞检测
3. **版本不匹配**: 正确实现版本协商流程
4. **包号重复**: 实现正确的包号空间管理

## 完成标准

- ✅ 能够正确解析和构造各种QUIC包类型
- ✅ 连接ID管理功能完整工作
- ✅ 版本协商流程通过测试
- ✅ 基础握手状态机运行正常
- ✅ 所有单元测试和集成测试通过
- ✅ 与现有QUIC实现的基础互操作性验证通过

完成这个阶段后，你将掌握QUIC协议的核心机制，为实现更高级的功能（如流管理和拥塞控制）奠定基础。