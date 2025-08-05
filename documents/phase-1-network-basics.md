# 阶段一：网络编程基础

## 学习目标

在这个阶段，我们将建立QUIC实现所需的网络编程基础，重点掌握：

- Swift Network.framework的使用
- UDP协议编程基础
- 异步网络编程模式
- 基础的包解析和构造
- 错误处理和连接管理

## 理论知识要点

### 1. UDP vs TCP基础对比

```
TCP特性：                    UDP特性：
✓ 可靠传输                   ✗ 不保证可靠性
✓ 有序传输                   ✗ 不保证顺序
✓ 流量控制                   ✗ 无流量控制
✓ 拥塞控制                   ✗ 无拥塞控制
✗ 连接建立开销               ✓ 无连接开销
✗ 队头阻塞                   ✓ 无队头阻塞
```

### 2. Swift Network.framework架构

```swift
Network.framework组件：
┌─────────────────┐
│   NWConnection  │  <- 连接抽象
├─────────────────┤
│  NWEndpoint     │  <- 端点定义
├─────────────────┤
│  NWParameters   │  <- 连接参数
├─────────────────┤
│  NWListener     │  <- 服务端监听
└─────────────────┘
```

### 3. 异步编程模式

QUIC的实现需要处理大量异步操作，Swift提供了多种方式：

- **Completion Handler**: 传统回调模式
- **Combine**: 响应式编程
- **async/await**: 现代异步语法（推荐）

## 实现任务清单

### 任务1：UDP Socket基础封装

**目标**: 创建基础的UDP连接抽象

**要求**:
- [ ] 实现`UDPConnection`类
- [ ] 支持客户端连接到指定端点
- [ ] 支持服务端监听指定端口
- [ ] 实现基础的发送和接收功能
- [ ] 添加连接状态管理

**核心接口设计**:
```swift
protocol UDPConnectionProtocol {
    func connect(to endpoint: NWEndpoint) async throws
    func send(data: Data) async throws
    func receive() async throws -> Data
    func close()
}
```

### 任务2：包解析器实现

**目标**: 实现基础的网络包解析功能

**要求**:
- [ ] 创建`PacketParser`结构
- [ ] 实现二进制数据的读取工具
- [ ] 支持网络字节序处理
- [ ] 实现包头字段提取
- [ ] 添加数据验证功能

**核心功能**:
```swift
struct PacketParser {
    func readUInt8() -> UInt8
    func readUInt16() -> UInt16
    func readUInt32() -> UInt32
    func readVariableInt() -> UInt64
    func readBytes(count: Int) -> Data
}
```

### 任务3：简单客户端-服务器Demo

**目标**: 实现一个基础的UDP通信demo

**要求**:
- [ ] 创建简单的Echo服务器
- [ ] 实现对应的客户端
- [ ] 支持多客户端并发连接
- [ ] 添加基础的错误处理
- [ ] 实现优雅的关闭流程

**示例交互流程**:
```
Client -> Server: "Hello QUIC!"
Server -> Client: "Echo: Hello QUIC!"
```

### 任务4：连接状态机

**目标**: 实现基础的连接状态管理

**要求**:
- [ ] 定义连接状态枚举
- [ ] 实现状态转换逻辑
- [ ] 添加状态变化通知
- [ ] 实现超时处理
- [ ] 支持连接重试机制

**状态定义**:
```swift
enum ConnectionState {
    case idle
    case connecting
    case connected
    case closing
    case closed
    case failed(Error)
}
```

## 代码示例

### 基础UDP连接实现

```swift
import Network
import Foundation

class UDPConnection: UDPConnectionProtocol {
    private var connection: NWConnection?
    private var state: ConnectionState = .idle
    
    func connect(to endpoint: NWEndpoint) async throws {
        let params = NWParameters.udp
        connection = NWConnection(to: endpoint, using: params)
        
        return try await withCheckedThrowingContinuation { continuation in
            connection?.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    self.state = .connected
                    continuation.resume()
                case .failed(let error):
                    self.state = .failed(error)
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            
            connection?.start(queue: .global())
        }
    }
    
    func send(data: Data) async throws {
        guard let connection = connection else {
            throw NetworkError.notConnected
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    func receive() async throws -> Data {
        guard let connection = connection else {
            throw NetworkError.notConnected
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: NetworkError.connectionClosed)
                }
            }
        }
    }
}
```

### 包解析器实现

```swift
struct PacketParser {
    private let data: Data
    private var offset: Int = 0
    
    init(data: Data) {
        self.data = data
    }
    
    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw ParsingError.insufficientData
        }
        let value = data[offset]
        offset += 1
        return value
    }
    
    mutating func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw ParsingError.insufficientData
        }
        let value = data.subdata(in: offset..<offset+2).withUnsafeBytes {
            $0.load(as: UInt16.self).bigEndian
        }
        offset += 2
        return value
    }
    
    mutating func readVariableInt() throws -> UInt64 {
        let firstByte = try readUInt8()
        let lengthBits = (firstByte & 0xC0) >> 6
        
        switch lengthBits {
        case 0: return UInt64(firstByte & 0x3F)
        case 1: 
            let secondByte = try readUInt8()
            return UInt64((firstByte & 0x3F)) << 8 | UInt64(secondByte)
        case 2:
            let bytes = try readBytes(count: 3)
            return bytes.withUnsafeBytes { 
                UInt64((firstByte & 0x3F)) << 24 | $0.load(as: UInt32.self).bigEndian 
            }
        case 3:
            let bytes = try readBytes(count: 7)
            return bytes.withUnsafeBytes { 
                UInt64((firstByte & 0x3F)) << 56 | $0.load(as: UInt64.self).bigEndian 
            }
        default:
            throw ParsingError.invalidVariableInt
        }
    }
}
```

## 测试验证

### 单元测试要求

- [ ] UDP连接建立和关闭测试
- [ ] 数据发送和接收测试
- [ ] 包解析器功能测试
- [ ] 错误处理测试
- [ ] 并发安全测试

### 集成测试场景

- [ ] 客户端-服务器基础通信
- [ ] 多客户端并发测试
- [ ] 网络错误恢复测试
- [ ] 大数据包传输测试
- [ ] 连接超时处理测试

### 性能基准测试

- [ ] 单连接吞吐量测试
- [ ] 并发连接数测试
- [ ] 内存使用分析
- [ ] CPU使用率分析

## 错误类型定义

```swift
enum NetworkError: Error {
    case notConnected
    case connectionClosed
    case invalidEndpoint
    case sendTimeout
    case receiveTimeout
}

enum ParsingError: Error {
    case insufficientData
    case invalidVariableInt
    case malformedPacket
    case unsupportedVersion
}
```

## 调试和工具

### 网络调试建议

1. **Wireshark抓包**: 验证UDP包的发送和接收
2. **Console日志**: 记录连接状态变化
3. **Network.framework日志**: 启用详细的网络日志
4. **单元测试**: 验证每个组件的正确性

### 常见问题和解决方案

1. **连接建立失败**: 检查防火墙和网络配置
2. **数据包丢失**: 在UDP层面是正常的，需要应用层处理
3. **并发问题**: 正确使用actor或串行队列
4. **内存泄漏**: 注意NWConnection的生命周期管理

## 进阶主题

完成基础任务后，可以探索：

- [ ] 实现包的批量发送和接收
- [ ] 添加基础的包重传机制
- [ ] 实现简单的带宽估算
- [ ] 支持IPv6双栈网络
- [ ] 添加网络路径监控

## 完成标准

当你完成以下所有任务时，可以进入下一阶段：

- ✅ 所有单元测试通过
- ✅ 客户端-服务器demo正常工作
- ✅ 代码通过Swift静态分析检查
- ✅ 性能测试满足基本要求
- ✅ 代码review和重构完成

这个阶段为后续的QUIC协议实现提供了坚实的网络编程基础。掌握这些基础概念和技能后，你就能够理解和实现更复杂的QUIC协议特性。