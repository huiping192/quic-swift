import Foundation

// MARK: - 包号管理器
public class PacketNumberManager {
    internal var spaces: [PacketNumberSpace: PacketSpaceState]
    internal let lock = NSLock()
    
    public init() {
        self.spaces = [:]
        
        // 初始化所有包号空间
        for space in PacketNumberSpace.allCases {
            spaces[space] = PacketSpaceState()
        }
    }
    
    // MARK: - 包号生成
    public func nextPacketNumber(for space: PacketNumberSpace) -> UInt64 {
        return lock.withLock {
            guard var spaceState = spaces[space] else {
                spaces[space] = PacketSpaceState()
                return 0
            }
            
            let packetNumber = spaceState.generateNextPacketNumber()
            spaces[space] = spaceState
            return packetNumber
        }
    }
    
    // MARK: - 包号验证
    public func validatePacketNumber(_ packetNumber: UInt64, in space: PacketNumberSpace) -> Bool {
        return lock.withLock {
            guard let spaceState = spaces[space] else {
                return true // 如果空间不存在，认为有效
            }
            
            return spaceState.isValidPacketNumber(packetNumber)
        }
    }
    
    // MARK: - 标记接收
    public func markReceived(_ packetNumber: UInt64, in space: PacketNumberSpace) -> Bool {
        return lock.withLock {
            guard var spaceState = spaces[space] else {
                var newState = PacketSpaceState()
                let wasNew = newState.markReceived(packetNumber)
                spaces[space] = newState
                return wasNew
            }
            
            let wasNew = spaceState.markReceived(packetNumber)
            spaces[space] = spaceState
            return wasNew
        }
    }
    
    // MARK: - 获取空间状态
    public func getSpaceState(for space: PacketNumberSpace) -> PacketSpaceState? {
        return lock.withLock {
            return spaces[space]
        }
    }
    
    // MARK: - 重置空间
    public func resetSpace(_ space: PacketNumberSpace) {
        lock.withLock {
            spaces[space] = PacketSpaceState()
        }
    }
    
    // MARK: - 获取统计信息
    public func getStatistics(for space: PacketNumberSpace) -> PacketSpaceStatistics? {
        return lock.withLock {
            guard let spaceState = spaces[space] else {
                return nil
            }
            
            return PacketSpaceStatistics(spaceState: spaceState)
        }
    }
    
    // MARK: - 获取所有空间统计
    public func getAllStatistics() -> [PacketNumberSpace: PacketSpaceStatistics] {
        return lock.withLock {
            var stats: [PacketNumberSpace: PacketSpaceStatistics] = [:]
            for (space, state) in spaces {
                stats[space] = PacketSpaceStatistics(spaceState: state)
            }
            return stats
        }
    }
    
    // MARK: - 清理旧包号
    public func cleanupOldPacketNumbers(in space: PacketNumberSpace, olderThan threshold: UInt64) {
        lock.withLock {
            guard var spaceState = spaces[space] else {
                return
            }
            
            spaceState.receivedPackets = spaceState.receivedPackets.filter { $0 >= threshold }
            spaces[space] = spaceState
        }
    }
}

// MARK: - 包号空间统计
public struct PacketSpaceStatistics {
    public let nextPacketNumber: UInt64
    public let largestReceived: UInt64?
    public let receivedPacketsCount: Int
    public let maxReceived: UInt64
    
    init(spaceState: PacketSpaceState) {
        self.nextPacketNumber = spaceState.nextPacketNumber
        self.largestReceived = spaceState.largestReceived
        self.receivedPacketsCount = spaceState.receivedPackets.count
        self.maxReceived = spaceState.maxReceived
    }
    
    public var debugDescription: String {
        return "PacketSpaceStats(next: \(nextPacketNumber), largest: \(largestReceived?.description ?? "nil"), received: \(receivedPacketsCount), max: \(maxReceived))"
    }
}

// MARK: - 包号范围管理
public struct PacketNumberRange {
    public let start: UInt64
    public let end: UInt64
    
    public init(start: UInt64, end: UInt64) {
        precondition(start <= end, "Invalid packet number range")
        self.start = start
        self.end = end
    }
    
    public func contains(_ packetNumber: UInt64) -> Bool {
        return packetNumber >= start && packetNumber <= end
    }
    
    public var count: UInt64 {
        return end - start + 1
    }
}

// MARK: - 高级包号管理器
public class AdvancedPacketNumberManager: PacketNumberManager {
    private var gaps: [PacketNumberSpace: [PacketNumberRange]] = [:]
    private let maxGapsPerSpace = 100 // 限制每个空间的间隙数量
    
    public override init() {
        super.init()
        
        // 初始化间隙跟踪
        for space in PacketNumberSpace.allCases {
            gaps[space] = []
        }
    }
    
    // MARK: - 间隙检测
    public func detectGaps(in space: PacketNumberSpace) -> [PacketNumberRange] {
        return lock.withLock {
            return gaps[space] ?? []
        }
    }
    
    // MARK: - 更新间隙
    public override func markReceived(_ packetNumber: UInt64, in space: PacketNumberSpace) -> Bool {
        let wasNew = super.markReceived(packetNumber, in: space)
        
        if wasNew {
            updateGapsAfterReceiving(packetNumber, in: space)
        }
        
        return wasNew
    }
    
    private func updateGapsAfterReceiving(_ packetNumber: UInt64, in space: PacketNumberSpace) {
        lock.withLock {
            guard let spaceState = spaces[space] else { return }
            guard let spaceGaps = gaps[space] else { return }
            
            // 查找并更新相关的间隙
            var updatedGaps: [PacketNumberRange] = []
            
            for gap in spaceGaps {
                if gap.contains(packetNumber) {
                    // 这个包号填补了间隙的一部分
                    if gap.start < packetNumber {
                        updatedGaps.append(PacketNumberRange(start: gap.start, end: packetNumber - 1))
                    }
                    if packetNumber < gap.end {
                        updatedGaps.append(PacketNumberRange(start: packetNumber + 1, end: gap.end))
                    }
                } else {
                    updatedGaps.append(gap)
                }
            }
            
            // 检测新的间隙（当接收到的包号大于当前最大接收包号+1时）
            let sortedReceivedPackets = spaceState.receivedPackets.sorted()
            if !sortedReceivedPackets.isEmpty {
                // 检查是否存在间隙
                for i in 0..<sortedReceivedPackets.count - 1 {
                    let current = sortedReceivedPackets[i]
                    let next = sortedReceivedPackets[i + 1]
                    if next > current + 1 {
                        // 发现间隙
                        let gapRange = PacketNumberRange(start: current + 1, end: next - 1)
                        // 检查这个间隙是否已存在
                        if !updatedGaps.contains(where: { $0.start == gapRange.start && $0.end == gapRange.end }) {
                            updatedGaps.append(gapRange)
                        }
                    }
                }
            }
            
            // 限制间隙数量
            if updatedGaps.count > maxGapsPerSpace {
                updatedGaps = Array(updatedGaps.suffix(maxGapsPerSpace))
            }
            
            gaps[space] = updatedGaps
        }
    }
    
    // MARK: - 丢包检测
    public func detectLostPackets(in space: PacketNumberSpace, threshold: Int = 3) -> [UInt64] {
        return lock.withLock {
            guard let spaceState = spaces[space] else { return [] }
            guard let largestReceived = spaceState.largestReceived else { return [] }
            
            var lostPackets: [UInt64] = []
            
            // 检查从0到largest_received之间缺失的包号
            for packetNumber in 0..<largestReceived {
                if !spaceState.receivedPackets.contains(packetNumber) {
                    // 检查是否超过阈值
                    let gapSize = largestReceived - packetNumber
                    if gapSize >= threshold {
                        lostPackets.append(packetNumber)
                    }
                }
            }
            
            return lostPackets
        }
    }
    
    // MARK: - 包号压缩
    public func compressPacketNumber(_ fullPacketNumber: UInt64, largestAcked: UInt64) -> (Data, Int) {
        let diff = fullPacketNumber - largestAcked
        
        if diff < 0x40 {
            // 1字节编码 (6位有效)
            let compressed = UInt8(diff)
            return (Data([compressed]), 1)
        } else if diff < 0x4000 {
            // 2字节编码 (14位有效)
            let compressed = UInt16(diff)
            var data = Data()
            data.append(UInt8((compressed >> 8) | 0x40))
            data.append(UInt8(compressed & 0xFF))
            return (data, 2)
        } else if diff < 0x40000000 {
            // 4字节编码 (30位有效)
            let compressed = UInt32(diff)
            var data = Data()
            data.append(UInt8((compressed >> 24) | 0x80))
            data.append(UInt8((compressed >> 16) & 0xFF))
            data.append(UInt8((compressed >> 8) & 0xFF))
            data.append(UInt8(compressed & 0xFF))
            return (data, 4)
        } else {
            // 超出范围，使用4字节编码截断
            let compressed = UInt32(diff & 0x3FFFFFFF)
            var data = Data()
            data.append(UInt8((compressed >> 24) | 0x80))
            data.append(UInt8((compressed >> 16) & 0xFF))
            data.append(UInt8((compressed >> 8) & 0xFF))
            data.append(UInt8(compressed & 0xFF))
            return (data, 4)
        }
    }
    
    // MARK: - 包号解压缩
    public func decompressPacketNumber(_ compressedData: Data, largestAcked: UInt64) -> UInt64? {
        guard !compressedData.isEmpty else { return nil }
        
        let firstByte = compressedData[0]
        let lengthBits = (firstByte & 0xC0) >> 6
        
        switch lengthBits {
        case 0: // 1字节编码 (00xxxxxx)
            let diff = UInt64(firstByte & 0x3F)
            return largestAcked + diff
            
        case 1: // 2字节编码 (01xxxxxx)
            guard compressedData.count >= 2 else { return nil }
            let diff = UInt64((firstByte & 0x3F)) << 8 | UInt64(compressedData[1])
            return largestAcked + diff
            
        case 2: // 4字节编码 (10xxxxxx)
            guard compressedData.count >= 4 else { return nil }
            let diff = UInt64((firstByte & 0x3F)) << 24 | 
                      UInt64(compressedData[1]) << 16 | 
                      UInt64(compressedData[2]) << 8 | 
                      UInt64(compressedData[3])
            return largestAcked + diff
            
        case 3: // 保留，当作4字节处理
            guard compressedData.count >= 4 else { return nil }
            let diff = UInt64((firstByte & 0x3F)) << 24 | 
                      UInt64(compressedData[1]) << 16 | 
                      UInt64(compressedData[2]) << 8 | 
                      UInt64(compressedData[3])
            return largestAcked + diff
            
        default:
            return nil
        }
    }
}