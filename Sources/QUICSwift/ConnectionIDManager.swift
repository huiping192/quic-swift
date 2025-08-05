import Foundation
import Security

// 前向声明
public protocol QUICConnectionProtocol: AnyObject {
    var connectionID: ConnectionID { get }
    func handlePacket(_ packet: QUICPacket) async throws
}

// MARK: - 连接弱引用包装器
internal class ConnectionWeakRef {
    weak var connection: (any QUICConnectionProtocol)?
    
    init(_ connection: any QUICConnectionProtocol) {
        self.connection = connection
    }
}

// MARK: - 连接ID管理器
public class ConnectionIDManager {
    internal var connectionMap: [ConnectionID: ConnectionWeakRef] = [:]
    internal var activeIDs: Set<ConnectionID> = []
    internal var retiredIDs: Set<ConnectionID> = []
    internal let lock = NSLock()
    private var cleanupTimer: Timer?
    
    // 配置参数
    private let maxActiveConnections = 1000
    private let cleanupInterval: TimeInterval = 60.0 // 60秒清理一次
    private let maxRetiredIDs = 100
    
    public init() {
        setupCleanupTimer()
    }
    
    deinit {
        cleanupTimer?.invalidate()
    }
    
    // MARK: - 连接ID生成
    public func generateConnectionID() -> ConnectionID {
        let length = UInt8.random(in: 8...20)
        var bytes = Data(count: Int(length))
        
        repeat {
            bytes.withUnsafeMutableBytes { bufferPointer in
                _ = SecRandomCopyBytes(kSecRandomDefault, Int(length), bufferPointer.baseAddress!)
            }
            let candidateID = ConnectionID(bytes: bytes, length: length)
            
            // 确保生成的ID不冲突
            if !isConnectionIDInUse(candidateID) {
                return candidateID
            }
        } while true
    }
    
    // MARK: - 连接注册和管理
    public func registerConnection(id: ConnectionID, connection: any QUICConnectionProtocol) throws {
        try lock.withLock {
            // 检查连接数限制
            guard activeIDs.count < maxActiveConnections else {
                throw QUICError.protocolViolation("Maximum active connections reached")
            }
            
            // 检查连接ID冲突
            guard !activeIDs.contains(id) else {
                throw QUICError.connectionIDCollision
            }
            
            // 检查是否为已退役的ID
            guard !retiredIDs.contains(id) else {
                throw QUICError.protocolViolation("Attempting to reuse retired connection ID")
            }
            
            connectionMap[id] = ConnectionWeakRef(connection)
            activeIDs.insert(id)
        }
    }
    
    public func unregisterConnection(id: ConnectionID) {
        lock.withLock {
            connectionMap.removeValue(forKey: id)
            activeIDs.remove(id)
        }
    }
    
    // MARK: - 包路由
    public func routePacket(_ packet: QUICPacket) -> (any QUICConnectionProtocol)? {
        return lock.withLock {
            let connectionID = packet.destinationConnectionID
            
            // 查找活跃连接
            if let weakRef = connectionMap[connectionID] {
                if let connection = weakRef.connection {
                    return connection
                } else {
                    // 清理失效的引用
                    connectionMap.removeValue(forKey: connectionID)
                    activeIDs.remove(connectionID)
                }
            }
            
            return nil
        }
    }
    
    // MARK: - 连接ID验证
    public func validateConnectionID(_ id: ConnectionID) -> Bool {
        return lock.withLock {
            // 检查长度
            guard id.length >= ConnectionID.minLength && id.length <= ConnectionID.maxLength else {
                return false
            }
            
            // 检查是否已退役
            guard !retiredIDs.contains(id) else {
                return false
            }
            
            return true
        }
    }
    
    public func isConnectionIDInUse(_ id: ConnectionID) -> Bool {
        return lock.withLock {
            return activeIDs.contains(id) || retiredIDs.contains(id)
        }
    }
    
    // MARK: - 连接ID退役
    public func retireConnectionID(_ id: ConnectionID) {
        lock.withLock {
            // 移除活跃连接
            connectionMap.removeValue(forKey: id)
            activeIDs.remove(id)
            
            // 添加到退役列表
            retiredIDs.insert(id)
            
            // 限制退役ID数量
            if retiredIDs.count > maxRetiredIDs {
                // 移除最旧的退役ID（简化实现）
                let oldestID = retiredIDs.first!
                retiredIDs.remove(oldestID)
            }
        }
    }
    
    // MARK: - 统计信息
    public func getStatistics() -> ConnectionIDManagerStatistics {
        return lock.withLock {
            return ConnectionIDManagerStatistics(
                activeConnections: activeIDs.count,
                retiredIDs: retiredIDs.count,
                totalRegistered: connectionMap.count
            )
        }
    }
    
    public func getAllActiveConnectionIDs() -> Set<ConnectionID> {
        return lock.withLock {
            return activeIDs
        }
    }
    
    public func getAllRetiredConnectionIDs() -> Set<ConnectionID> {
        return lock.withLock {
            return retiredIDs
        }
    }
    
    // MARK: - 清理和维护
    private func setupCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupInterval, repeats: true) { [weak self] _ in
            self?.performCleanup()
        }
    }
    
    private func performCleanup() {
        lock.withLock {
            cleanupStaleReferences()
        }
    }
    
    private func cleanupStaleReferences() {
        var staleIDs: [ConnectionID] = []
        
        for (id, weakRef) in connectionMap {
            if weakRef.connection == nil {
                staleIDs.append(id)
            }
        }
        
        for id in staleIDs {
            connectionMap.removeValue(forKey: id)
            activeIDs.remove(id)
        }
    }
    
    public func forceCleanup() {
        lock.withLock {
            cleanupStaleReferences()
        }
    }
    
    // MARK: - 连接查找和过滤
    public func findConnections(matching predicate: (any QUICConnectionProtocol) -> Bool) -> [any QUICConnectionProtocol] {
        return lock.withLock {
            let connections = connectionMap.values.compactMap { $0.connection }
            return connections.filter(predicate)
        }
    }
    
    public func getConnectionCount() -> Int {
        return lock.withLock {
            return activeIDs.count
        }
    }
    
    // MARK: - 调试和诊断
    public func debugInfo() -> String {
        return lock.withLock {
            var info = "ConnectionIDManager Debug Info:\n"
            info += "  Active Connections: \(activeIDs.count)\n"
            info += "  Retired IDs: \(retiredIDs.count)\n"
            info += "  Map Entries: \(connectionMap.count)\n"
            
            info += "  Active Connection IDs:\n"
            for (index, id) in activeIDs.enumerated() {
                info += "    \(index + 1). \(id.debugDescription)\n"
            }
            
            if !retiredIDs.isEmpty {
                info += "  Retired Connection IDs:\n"
                for (index, id) in retiredIDs.enumerated() {
                    info += "    \(index + 1). \(id.debugDescription)\n"
                }
            }
            
            return info
        }
    }
}

// MARK: - 连接ID管理器统计
public struct ConnectionIDManagerStatistics {
    public let activeConnections: Int
    public let retiredIDs: Int
    public let totalRegistered: Int
    
    public var debugDescription: String {
        return "CIDManagerStats(active: \(activeConnections), retired: \(retiredIDs), total: \(totalRegistered))"
    }
}

// MARK: - 高级连接ID管理器
public class AdvancedConnectionIDManager: ConnectionIDManager {
    private var connectionIDSequences: [ConnectionID: UInt64] = [:]
    private var loadBalancingEnabled = false
    private var connectionLoadMetrics: [ConnectionID: ConnectionLoadMetric] = [:]
    
    public override init() {
        super.init()
    }
    
    // MARK: - 序列号管理
    public func generateSequentialConnectionID(baseID: ConnectionID) -> ConnectionID {
        return lock.withLock {
            let currentSequence = connectionIDSequences[baseID] ?? 0
            let newSequence = currentSequence + 1
            connectionIDSequences[baseID] = newSequence
            
            // 基于基础ID和序列号生成新的连接ID
            var newBytes = baseID.bytes
            let sequenceBytes = withUnsafeBytes(of: newSequence.bigEndian) { Array($0) }
            
            // 将序列号的最后4字节追加到基础ID
            if newBytes.count >= 4 {
                let startIndex = newBytes.count - 4
                for (i, byte) in sequenceBytes.suffix(4).enumerated() {
                    newBytes[startIndex + i] = byte
                }
            }
            
            return ConnectionID(bytes: newBytes)
        }
    }
    
    // MARK: - 负载均衡
    public func enableLoadBalancing(_ enabled: Bool) {
        loadBalancingEnabled = enabled
    }
    
    public override func routePacket(_ packet: QUICPacket) -> (any QUICConnectionProtocol)? {
        let connection = super.routePacket(packet)
        
        if loadBalancingEnabled, connection != nil {
            updateLoadMetrics(for: packet.destinationConnectionID)
        }
        
        return connection
    }
    
    private func updateLoadMetrics(for connectionID: ConnectionID) {
        lock.withLock {
            if var metric = connectionLoadMetrics[connectionID] {
                metric.incrementPacketCount()
                connectionLoadMetrics[connectionID] = metric
            } else {
                connectionLoadMetrics[connectionID] = ConnectionLoadMetric()
            }
        }
    }
    
    public func getLoadMetrics() -> [ConnectionID: ConnectionLoadMetric] {
        return lock.withLock {
            return connectionLoadMetrics
        }
    }
    
    // MARK: - 连接迁移支持
    public func migrateConnection(from oldID: ConnectionID, to newID: ConnectionID) throws {
        try lock.withLock {
            guard let weakRef = connectionMap[oldID] else {
                throw QUICError.invalidConnectionID
            }
            
            guard weakRef.connection != nil else {
                throw QUICError.protocolViolation("Connection no longer exists")
            }
            
            // 验证新ID不冲突
            guard !isConnectionIDInUse(newID) else {
                throw QUICError.connectionIDCollision
            }
            
            // 执行迁移
            connectionMap[newID] = weakRef
            activeIDs.insert(newID)
            
            // 退役旧ID
            retireConnectionID(oldID)
        }
    }
}

// MARK: - 连接负载指标
public struct ConnectionLoadMetric {
    public private(set) var packetCount: UInt64 = 0
    public private(set) var lastActivityTime: Date = Date()
    
    public mutating func incrementPacketCount() {
        packetCount += 1
        lastActivityTime = Date()
    }
    
    public var packetsPerSecond: Double {
        let timeSinceLastActivity = Date().timeIntervalSince(lastActivityTime)
        guard timeSinceLastActivity > 0 else { return 0 }
        return Double(packetCount) / timeSinceLastActivity
    }
    
    public var debugDescription: String {
        return "LoadMetric(packets: \(packetCount), pps: \(String(format: "%.2f", packetsPerSecond)))"
    }
}