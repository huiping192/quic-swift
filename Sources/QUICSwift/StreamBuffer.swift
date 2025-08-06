import Foundation

// MARK: - 流缓冲区
public class StreamBuffer {
    // 分离的发送和接收缓冲区
    private var sendSegments: [StreamSegment] = []
    private var receiveSegments: [StreamSegment] = []
    private var readOffset: UInt64 = 0
    private var writeOffset: UInt64 = 0
    private var isComplete: Bool = false
    private var totalBytesReceived: UInt64 = 0
    private var totalBytesSent: UInt64 = 0
    private let lock = NSLock()
    private let maxBufferSize: Int
    
    public struct StreamSegment {
        let offset: UInt64
        let data: Data
        let endOffset: UInt64
        
        init(offset: UInt64, data: Data) {
            self.offset = offset
            self.data = data
            self.endOffset = offset + UInt64(data.count)
        }
        
        func overlaps(with other: StreamSegment) -> Bool {
            return !(endOffset <= other.offset || other.endOffset <= offset)
        }
        
        func contains(offset: UInt64) -> Bool {
            return offset >= self.offset && offset < endOffset
        }
    }
    
    public init(maxBufferSize: Int = 1024 * 1024) { // 默认1MB缓冲区
        self.maxBufferSize = maxBufferSize
    }
    
    // MARK: - 数据写入（发送缓冲区）
    public func append(_ data: Data) throws {
        try lock.withLock {
            guard sendCurrentSize + data.count <= maxBufferSize else {
                throw StreamError.bufferOverflow
            }
            
            let segment = StreamSegment(offset: writeOffset, data: data)
            sendSegments.append(segment)
            writeOffset += UInt64(data.count)
            totalBytesSent += UInt64(data.count)
        }
    }
    
    public func getDataToSend(maxBytes: Int) -> (data: Data, offset: UInt64)? {
        return lock.withLock {
            guard let firstSegment = sendSegments.first else {
                return nil
            }
            
            let bytesToSend = min(maxBytes, firstSegment.data.count)
            let dataToSend = firstSegment.data.prefix(bytesToSend)
            
            return (Data(dataToSend), firstSegment.offset)
        }
    }
    
    public func markSent(bytes: Int) {
        lock.withLock {
            guard let firstSegment = sendSegments.first else {
                return
            }
            
            if bytes >= firstSegment.data.count {
                // 整个段已发送
                sendSegments.removeFirst()
            } else {
                // 部分发送，更新段
                let remainingData = firstSegment.data.dropFirst(bytes)
                let newOffset = firstSegment.offset + UInt64(bytes)
                let newSegment = StreamSegment(offset: newOffset, data: Data(remainingData))
                sendSegments[0] = newSegment
            }
        }
    }
    
    // MARK: - 数据接收（接收缓冲区）
    public func addData(_ data: Data, at offset: UInt64) throws {
        try lock.withLock {
            guard receiveCurrentSize + data.count <= maxBufferSize else {
                throw StreamError.bufferOverflow
            }
            
            let segment = StreamSegment(offset: offset, data: data)
            
            // 检查完全重复的段（相同偏移量和相同数据）
            if receiveSegments.contains(where: { $0.offset == offset && $0.data == data }) {
                return // 忽略完全重复的数据
            }
            
            // 查找插入位置
            let insertIndex = receiveSegments.firstIndex { $0.offset > offset } ?? receiveSegments.count
            receiveSegments.insert(segment, at: insertIndex)
            
            totalBytesReceived += UInt64(data.count)
            
            // 合并重叠的段
            try mergeOverlappingReceiveSegments()
        }
    }
    
    public func read() -> Data? {
        return lock.withLock {
            guard let firstSegment = receiveSegments.first,
                  firstSegment.offset == readOffset else {
                return nil
            }
            
            let data = firstSegment.data
            readOffset = firstSegment.endOffset
            receiveSegments.removeFirst()
            
            return data
        }
    }
    
    public func readUpTo(_ maxBytes: Int) -> Data? {
        return lock.withLock {
            guard let firstSegment = receiveSegments.first,
                  firstSegment.offset == readOffset else {
                return nil
            }
            
            if firstSegment.data.count <= maxBytes {
                // 读取整个段
                let data = firstSegment.data
                readOffset = firstSegment.endOffset
                receiveSegments.removeFirst()
                return data
            } else {
                // 读取部分数据
                let data = firstSegment.data.prefix(maxBytes)
                let remainingData = firstSegment.data.dropFirst(maxBytes)
                let newOffset = firstSegment.offset + UInt64(maxBytes)
                let newSegment = StreamSegment(offset: newOffset, data: Data(remainingData))
                receiveSegments[0] = newSegment
                readOffset += UInt64(maxBytes)
                return Data(data)
            }
        }
    }
    
    // MARK: - 状态查询
    public func hasData() -> Bool {
        return lock.withLock {
            return !receiveSegments.isEmpty && receiveSegments.first!.offset == readOffset
        }
    }
    
    public func canAcceptOffset(_ offset: UInt64) -> Bool {
        return lock.withLock {
            // 检查重复数据
            return !receiveSegments.contains { segment in
                segment.contains(offset: offset)
            }
        }
    }
    
    public var currentSize: Int {
        return sendCurrentSize + receiveCurrentSize
    }
    
    private var sendCurrentSize: Int {
        return sendSegments.reduce(0) { $0 + $1.data.count }
    }
    
    private var receiveCurrentSize: Int {
        return receiveSegments.reduce(0) { $0 + $1.data.count }
    }
    
    public var availableData: Int {
        return lock.withLock {
            guard let firstSegment = receiveSegments.first,
                  firstSegment.offset == readOffset else {
                return 0
            }
            
            var size = 0
            var currentOffset = readOffset
            
            for segment in receiveSegments {
                if segment.offset == currentOffset {
                    size += segment.data.count
                    currentOffset = segment.endOffset
                } else {
                    break
                }
            }
            
            return size
        }
    }
    
    public func markComplete() {
        lock.withLock {
            isComplete = true
        }
    }
    
    public var isCompleted: Bool {
        return lock.withLock {
            return isComplete
        }
    }
    
    // 发送缓冲区专用方法
    public var sendBufferSize: Int {
        return sendCurrentSize
    }
    
    public var sendOffset: UInt64 {
        return writeOffset
    }
    
    public func markSendComplete() {
        lock.withLock {
            isComplete = true
        }
    }
    
    public var isSendCompleted: Bool {
        return lock.withLock {
            return isComplete
        }
    }
    
    public var isEmpty: Bool {
        return lock.withLock {
            return receiveSegments.isEmpty && sendSegments.isEmpty
        }
    }
    
    public func clear() {
        lock.withLock {
            receiveSegments.removeAll()
            sendSegments.removeAll()
            readOffset = 0
            writeOffset = 0
            isComplete = false
        }
    }
    
    // MARK: - 内部方法
    private func mergeOverlappingReceiveSegments() throws {
        // 按偏移量排序
        receiveSegments.sort { $0.offset < $1.offset }
        
        var merged: [StreamSegment] = []
        
        for segment in receiveSegments {
            if let last = merged.last {
                if last.endOffset > segment.offset {
                    // 有真正的重叠，处理重叠部分
                    // 第一个段保持不变
                    // 第二个段只保留非重叠部分
                    if segment.endOffset > last.endOffset {
                        // 创建只包含非重叠部分的新段
                        let overlapBytes = Int(last.endOffset - segment.offset)
                        let nonOverlappingData = Data(segment.data.dropFirst(overlapBytes))
                        if !nonOverlappingData.isEmpty {
                            let nonOverlappingSegment = StreamSegment(offset: last.endOffset, data: nonOverlappingData)
                            merged.append(nonOverlappingSegment)
                        }
                    }
                    // 如果segment完全被last包含，则跳过segment
                } else {
                    // 没有重叠，保持独立（包括相邻的情况）
                    merged.append(segment)
                }
            } else {
                merged.append(segment)
            }
        }
        
        receiveSegments = merged
    }
    
    // MARK: - 调试和统计
    public func getStatistics() -> (totalReceived: UInt64, totalSent: UInt64, bufferSize: Int, segments: Int) {
        return lock.withLock {
            return (totalBytesReceived, totalBytesSent, currentSize, receiveSegments.count + sendSegments.count)
        }
    }
    
    public func debugInfo() -> String {
        return lock.withLock {
            return """
            StreamBuffer Info:
              Total Received: \(totalBytesReceived) bytes
              Total Sent: \(totalBytesSent) bytes
              Current Size: \(currentSize) bytes
              Send Segments: \(sendSegments.count)\n              Receive Segments: \(receiveSegments.count)
              Read Offset: \(readOffset)
              Write Offset: \(writeOffset)
              Is Complete: \(isComplete)
              Available Data: \(availableData) bytes
            """
        }
    }
    
    public func getGaps() -> [Range<UInt64>] {
        return lock.withLock {
            var gaps: [Range<UInt64>] = []
            
            if receiveSegments.isEmpty {
                return gaps
            }
            
            let sortedSegments = receiveSegments.sorted { $0.offset < $1.offset }
            
            // 检查第一个段之前的间隙
            if sortedSegments.first!.offset > readOffset {
                gaps.append(readOffset..<sortedSegments.first!.offset)
            }
            
            // 检查段之间的间隙
            for i in 0..<sortedSegments.count - 1 {
                let current = sortedSegments[i]
                let next = sortedSegments[i + 1]
                
                if current.endOffset < next.offset {
                    gaps.append(current.endOffset..<next.offset)
                }
            }
            
            return gaps
        }
    }
}