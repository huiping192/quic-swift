# 阶段三：流管理

## 学习目标

在掌握QUIC核心概念的基础上，这个阶段将实现QUIC的关键特性 - 流管理系统：

- QUIC流的概念和生命周期管理
- 多路复用机制实现
- 流级别的流量控制
- 连接级别的流量控制
- 流帧（STREAM Frame）的处理
- 流状态机和错误处理
- 流的优先级和调度

## 理论知识要点

### 1. QUIC流的基本概念

QUIC流是一个轻量级的、有序的字节流，具有以下特性：

```
流的特性：
✓ 双向或单向数据传输
✓ 独立的流量控制
✓ 有序的字节传输
✓ 无队头阻塞（流之间）
✓ 动态创建和销毁
```

### 2. 流ID编码规则

```
流ID的bit组成：
┌─────────────────────────────────────────────────┐
│  Stream ID (62 bits)                            │
├─────────────────────────────────────────────────┤
│ xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx DD │
└─────────────────────────────────────────────────┘
                                              ││
                                              │└─ Direction (0=client, 1=server)
                                              └── Type (0=bidirectional, 1=unidirectional)

Stream ID类型：
- 0x00: Client-initiated bidirectional
- 0x01: Server-initiated bidirectional  
- 0x02: Client-initiated unidirectional
- 0x03: Server-initiated unidirectional
```

### 3. 流状态机

```swift
enum StreamState {
    case idle           // 流未创建
    case open           // 流已创建，可读写
    case halfClosed     // 一个方向已关闭
    case closed         // 流完全关闭
    case resetSent      // 发送了RESET_STREAM
    case resetReceived  // 接收了RESET_STREAM
}
```

### 4. 流帧格式

#### STREAM帧
```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
|0|0|0|1|F|L|O|F|  <- Type=0x08-0x0f, FIN, LEN, OFFSET flags
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Stream ID (i)                       ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        [Offset (i)]                        ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        [Length (i)]                        ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Stream Data (*)                     ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

#### RESET_STREAM帧
```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
|    0x04       |  <- Type
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Stream ID (i)                       ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                  Application Error Code (i)                ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Final Size (i)                      ...
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 5. 流量控制机制

QUIC实现两级流量控制：

```
连接级流量控制：
┌─────────────────────────────────────┐
│  Connection Flow Control Window     │
│  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐   │
│  │ S1  │ │ S2  │ │ S3  │ │ S4  │   │
│  └─────┘ └─────┘ └─────┘ └─────┘   │
└─────────────────────────────────────┘

流级流量控制：
┌─────────────────┐
│  Stream Window  │
│  ┌───────────┐   │
│  │   Data    │   │
│  └───────────┘   │
└─────────────────┘
```

## 实现任务清单

### 任务1：流管理器核心

**目标**: 实现QUIC流的创建、管理和路由功能

**要求**:
- [ ] 实现`StreamManager`类
- [ ] 支持双向和单向流的创建
- [ ] 实现流ID分配和验证
- [ ] 支持流的路由和查找
- [ ] 实现流的生命周期管理
- [ ] 添加流数量限制控制

**核心接口**:
```swift
class StreamManager {
    func createStream(type: StreamType, initiator: StreamInitiator) -> QUICStream
    func getStream(id: UInt64) -> QUICStream?
    func closeStream(id: UInt64)
    func resetStream(id: UInt64, errorCode: UInt64)
    func routeStreamFrame(_ frame: StreamFrame) -> QUICStream?
    func getAllActiveStreams() -> [QUICStream]
}
```

### 任务2：QUIC流实现

**目标**: 实现单个QUIC流的完整功能

**要求**:
- [ ] 实现`QUICStream`类
- [ ] 支持有序数据写入和读取
- [ ] 实现流状态机
- [ ] 支持流的关闭和重置
- [ ] 实现数据缓冲和重组
- [ ] 添加流级别的错误处理

**流接口设计**:
```swift
class QUICStream {
    let id: UInt64
    let type: StreamType
    private(set) var state: StreamState
    
    func write(data: Data) async throws
    func read() async throws -> Data?
    func close() async throws
    func reset(errorCode: UInt64) async throws
    func canWrite() -> Bool
    func canRead() -> Bool
}
```

### 任务3：流帧处理

**目标**: 实现STREAM帧和相关控制帧的处理

**要求**:
- [ ] 实现`StreamFrame`结构
- [ ] 支持STREAM帧的解析和构造
- [ ] 实现RESET_STREAM帧处理
- [ ] 支持MAX_STREAM_DATA帧
- [ ] 实现STREAM_DATA_BLOCKED帧
- [ ] 添加帧验证和错误检测

**帧结构定义**:
```swift
struct StreamFrame {
    let streamID: UInt64
    let offset: UInt64
    let data: Data
    let fin: Bool
    let length: UInt64?
    
    static func parse(from data: Data) throws -> StreamFrame
    func serialize() -> Data
}

struct ResetStreamFrame {
    let streamID: UInt64
    let errorCode: UInt64
    let finalSize: UInt64
}
```

### 任务4：流量控制实现

**目标**: 实现QUIC的双级流量控制机制

**要求**:
- [ ] 实现`FlowController`类
- [ ] 支持流级别流量控制
- [ ] 支持连接级别流量控制
- [ ] 实现窗口更新机制
- [ ] 支持背压（backpressure）处理
- [ ] 添加流量控制的监控和调试

**流量控制接口**:
```swift
class FlowController {
    func canSend(streamID: UInt64, bytes: Int) -> Bool
    func consumeCredit(streamID: UInt64, bytes: Int)
    func addCredit(streamID: UInt64, bytes: Int)
    func getStreamWindow(streamID: UInt64) -> Int
    func getConnectionWindow() -> Int
    func handleMaxStreamData(_ frame: MaxStreamDataFrame)
    func handleMaxData(_ frame: MaxDataFrame)
}
```

### 任务5：多路复用调度器

**目标**: 实现高效的流调度和多路复用功能

**要求**:
- [ ] 实现`StreamScheduler`类
- [ ] 支持流优先级调度
- [ ] 实现公平调度算法
- [ ] 支持带宽分配
- [ ] 添加调度策略配置
- [ ] 实现调度性能监控

**调度器设计**:
```swift
class StreamScheduler {
    func scheduleStreams() -> [QUICStream]
    func addStream(_ stream: QUICStream, priority: StreamPriority)
    func removeStream(id: UInt64)
    func updatePriority(streamID: UInt64, priority: StreamPriority)
    func setSchedulingPolicy(_ policy: SchedulingPolicy)
}
```

## 代码示例

### QUIC流实现

```swift
class QUICStream {
    let id: UInt64
    let type: StreamType
    private(set) var state: StreamState = .idle
    
    private var sendBuffer: StreamBuffer
    private var receiveBuffer: StreamBuffer
    private var flowController: StreamFlowController
    private let stateQueue = DispatchQueue(label: "stream.state")
    
    init(id: UInt64, type: StreamType, initialWindowSize: UInt64) {
        self.id = id
        self.type = type
        self.sendBuffer = StreamBuffer()
        self.receiveBuffer = StreamBuffer()
        self.flowController = StreamFlowController(initialWindow: initialWindowSize)
    }
    
    func write(data: Data) async throws {
        try await stateQueue.async {
            guard self.canWrite() else {
                throw StreamError.streamNotWritable
            }
            
            guard self.flowController.canSend(bytes: data.count) else {
                throw StreamError.flowControlBlocked
            }
            
            self.sendBuffer.append(data)
            self.flowController.consumeCredit(bytes: data.count)
        }
        
        // 通知连接发送数据
        await notifyConnectionForSend()
    }
    
    func read() async throws -> Data? {
        return try await stateQueue.async {
            guard self.canRead() else {
                return nil
            }
            
            return self.receiveBuffer.read()
        }
    }
    
    func handleStreamFrame(_ frame: StreamFrame) async throws {
        try await stateQueue.async {
            // 验证流状态
            guard self.state == .open || self.state == .halfClosed else {
                throw StreamError.invalidStreamState
            }
            
            // 检查偏移量
            guard self.receiveBuffer.canAcceptOffset(frame.offset) else {
                throw StreamError.invalidOffset
            }
            
            // 添加数据到接收缓冲区
            self.receiveBuffer.addData(frame.data, at: frame.offset)
            
            // 处理FIN标志
            if frame.fin {
                self.receiveBuffer.markComplete()
                self.updateState(event: .receivedFin)
            }
            
            // 更新流量控制窗口
            self.flowController.addReceiveCredit(bytes: frame.data.count)
        }
    }
    
    func close() async throws {
        try await stateQueue.async {
            guard self.state == .open else {
                throw StreamError.streamAlreadyClosed
            }
            
            self.sendBuffer.markComplete()
            self.updateState(event: .sentFin)
        }
        
        await notifyConnectionForSend()
    }
    
    func reset(errorCode: UInt64) async throws {
        try await stateQueue.async {
            self.state = .resetSent
            self.sendBuffer.clear()
            self.receiveBuffer.clear()
        }
        
        await notifyConnectionForReset(errorCode: errorCode)
    }
    
    private func updateState(event: StreamEvent) {
        switch (state, event) {
        case (.idle, .created):
            state = .open
        case (.open, .sentFin):
            state = .halfClosed
        case (.open, .receivedFin):
            state = .halfClosed
        case (.halfClosed, .receivedFin), (.halfClosed, .sentFin):
            state = .closed
        case (_, .reset):
            state = .resetReceived
        default:
            break // 无效的状态转换
        }
    }
    
    func canWrite() -> Bool {
        return state == .open && !sendBuffer.isComplete
    }
    
    func canRead() -> Bool {
        return (state == .open || state == .halfClosed) && receiveBuffer.hasData()
    }
}
```

### 流缓冲区实现

```swift
class StreamBuffer {
    private var segments: [StreamSegment] = []
    private var readOffset: UInt64 = 0
    private var isComplete: Bool = false
    private let lock = NSLock()
    
    struct StreamSegment {
        let offset: UInt64
        let data: Data
        let endOffset: UInt64
        
        init(offset: UInt64, data: Data) {
            self.offset = offset
            self.data = data
            self.endOffset = offset + UInt64(data.count)
        }
    }
    
    func addData(_ data: Data, at offset: UInt64) {
        lock.withLock {
            let segment = StreamSegment(offset: offset, data: data)
            
            // 查找插入位置
            let insertIndex = segments.firstIndex { $0.offset > offset } ?? segments.count
            segments.insert(segment, at: insertIndex)
            
            // 合并重叠的段
            mergeOverlappingSegments()
        }
    }
    
    func read() -> Data? {
        return lock.withLock {
            guard let firstSegment = segments.first,
                  firstSegment.offset == readOffset else {
                return nil
            }
            
            let data = firstSegment.data
            readOffset = firstSegment.endOffset
            segments.removeFirst()
            
            return data
        }
    }
    
    func hasData() -> Bool {
        return lock.withLock {
            return !segments.isEmpty && segments.first!.offset == readOffset
        }
    }
    
    func canAcceptOffset(_ offset: UInt64) -> Bool {
        return lock.withLock {
            // 检查重复数据
            return !segments.contains { segment in
                offset >= segment.offset && offset < segment.endOffset
            }
        }
    }
    
    private func mergeOverlappingSegments() {
        // 合并相邻或重叠的段
        var merged: [StreamSegment] = []
        
        for segment in segments.sorted(by: { $0.offset < $1.offset }) {
            if let last = merged.last,
               last.endOffset >= segment.offset {
                // 合并段
                let combinedData = last.data + segment.data.dropFirst(Int(last.endOffset - segment.offset))
                let mergedSegment = StreamSegment(offset: last.offset, data: combinedData)
                merged[merged.count - 1] = mergedSegment
            } else {
                merged.append(segment)
            }
        }
        
        segments = merged
    }
}
```

### 流管理器实现

```swift
class StreamManager {
    private var streams: [UInt64: QUICStream] = [:]
    private var nextClientStreamID: UInt64 = 0
    private var nextServerStreamID: UInt64 = 1
    private var maxStreams: UInt64 = 1000
    private let lock = NSLock()
    
    func createStream(type: StreamType, initiator: StreamInitiator) -> QUICStream {
        return lock.withLock {
            let streamID = generateStreamID(type: type, initiator: initiator)
            let stream = QUICStream(id: streamID, type: type, initialWindowSize: 65536)
            streams[streamID] = stream
            return stream
        }
    }
    
    func getStream(id: UInt64) -> QUICStream? {
        return lock.withLock {
            return streams[id]
        }
    }
    
    func routeStreamFrame(_ frame: StreamFrame) -> QUICStream? {
        return lock.withLock {
            // 如果流不存在，可能需要创建新流（peer-initiated）
            if streams[frame.streamID] == nil {
                if canCreatePeerStream(frame.streamID) {
                    let type = StreamType.fromStreamID(frame.streamID)
                    let stream = QUICStream(id: frame.streamID, type: type, initialWindowSize: 65536)
                    streams[frame.streamID] = stream
                }
            }
            return streams[frame.streamID]
        }
    }
    
    func closeStream(id: UInt64) {
        lock.withLock {
            streams[id]?.close()
        }
    }
    
    func resetStream(id: UInt64, errorCode: UInt64) {
        lock.withLock {
            streams[id]?.reset(errorCode: errorCode)
            streams.removeValue(forKey: id)
        }
    }
    
    private func generateStreamID(type: StreamType, initiator: StreamInitiator) -> UInt64 {
        switch (initiator, type) {
        case (.client, .bidirectional):
            let id = nextClientStreamID
            nextClientStreamID += 4
            return id
        case (.client, .unidirectional):
            let id = nextClientStreamID + 2
            nextClientStreamID += 4
            return id
        case (.server, .bidirectional):
            let id = nextServerStreamID
            nextServerStreamID += 4
            return id
        case (.server, .unidirectional):
            let id = nextServerStreamID + 2
            nextServerStreamID += 4
            return id
        }
    }
    
    private func canCreatePeerStream(_ streamID: UInt64) -> Bool {
        // 检查流限制和流ID有效性
        return streams.count < maxStreams && isValidPeerStreamID(streamID)
    }
}
```

## 测试验证

### 单元测试要求

- [ ] 流创建和ID分配测试
- [ ] 流状态机转换测试
- [ ] 数据写入和读取测试
- [ ] 流量控制功能测试
- [ ] 流帧解析和构造测试
- [ ] 流重置和关闭测试

### 集成测试场景

- [ ] 多流并发读写测试
- [ ] 流量控制窗口耗尽测试
- [ ] 流优先级调度测试
- [ ] 异常流处理测试
- [ ] 大数据传输测试

### 性能测试要求

- [ ] 单流吞吐量测试
- [ ] 多流并发性能测试
- [ ] 内存使用效率测试
- [ ] 流创建销毁性能测试

## 调试和监控

### 流状态监控

```swift
extension QUICStream {
    var debugInfo: StreamDebugInfo {
        return StreamDebugInfo(
            id: id,
            state: state,
            sendBufferSize: sendBuffer.size,
            receiveBufferSize: receiveBuffer.size,
            flowControlWindow: flowController.sendWindow,
            bytesReceived: receiveBuffer.totalBytesReceived,
            bytesSent: sendBuffer.totalBytesSent
        )
    }
}
```

### 性能指标

- 流的创建/销毁速率
- 活跃流数量
- 平均流生命周期
- 流量控制阻塞事件
- 数据传输吞吐量

## 常见问题和解决方案

1. **流ID冲突**: 严格按照QUIC规范分配流ID
2. **内存泄漏**: 及时清理关闭的流和相关资源
3. **流量控制死锁**: 正确实现双向的流量控制更新
4. **数据重组错误**: 仔细处理乱序和重复的数据段
5. **状态同步问题**: 使用适当的锁机制保护共享状态

## 完成标准

- ✅ 流的完整生命周期管理正常工作
- ✅ 多路复用功能正确实现
- ✅ 流量控制机制有效运行
- ✅ 所有流帧类型正确处理
- ✅ 性能测试达到预期指标
- ✅ 内存使用在合理范围内
- ✅ 并发安全性验证通过

完成这个阶段后，你将掌握QUIC最核心的流管理功能，这是QUIC相比TCP的最大优势之一。接下来可以进入高级特性的实现阶段。