import Foundation

// MARK: - 丢包和拥塞管理器
/// 集成丢包检测和拥塞控制的管理器，实现两者之间的协调工作
public class LossAndCongestionManager {
    
    // 核心组件
    private let lossDetector: LossDetector
    private let congestionController: CongestionController
    
    // 统计信息
    private var totalPacketsSent: UInt64 = 0
    private var totalPacketsLost: UInt64 = 0
    private var totalPacketsAcked: UInt64 = 0
    private var totalCongestionEvents: UInt64 = 0
    
    // 代理
    public weak var delegate: LossAndCongestionDelegate?
    
    public init(
        lossDetector: LossDetector = LossDetector(),
        congestionController: CongestionController = NewRenoCongestionController()
    ) {
        self.lossDetector = lossDetector
        self.congestionController = congestionController
        
        // 设置丢包检测器的代理
        self.lossDetector.delegate = self
    }
    
    // MARK: - 包发送处理
    
    public func onPacketSent(_ packet: SentPacket) {
        totalPacketsSent += 1
        
        // 通知两个组件
        lossDetector.onPacketSent(packet)
        congestionController.onPacketSent(packet: packet)
        
        // 通知代理
        delegate?.lossAndCongestionManager(self, didSendPacket: packet)
    }
    
    // MARK: - 包确认处理
    
    public func onPacketAcknowledged(ackedPackets: [AckedPacket]) {
        totalPacketsAcked += UInt64(ackedPackets.count)
        
        // 使用丢包检测器处理确认，获取丢包和RTT信息
        let result = lossDetector.onAckReceived(ackedPackets: ackedPackets)
        
        // 将确认信息传递给拥塞控制器
        for ackedPacket in ackedPackets {
            // 使用平均RTT，如果有RTT样本的话
            let rtt = result.rttSamples.isEmpty ? lossDetector.smoothedRTT : 
                     result.rttSamples.map { $0.rtt }.reduce(0, +) / Double(result.rttSamples.count)
            
            congestionController.onPacketAcked(packet: ackedPacket, rtt: rtt)
        }
        
        // 处理检测到的丢包
        if !result.lostPackets.isEmpty {
            handlePacketLoss(result.lostPackets)
        }
        
        // 通知代理
        delegate?.lossAndCongestionManager(self, didAcknowledgePackets: ackedPackets, withLostPackets: result.lostPackets)
    }
    
    // MARK: - 丢包处理
    
    private func handlePacketLoss(_ lostPackets: [LostPacket]) {
        totalPacketsLost += UInt64(lostPackets.count)
        totalCongestionEvents += 1
        
        // 将丢包信息传递给拥塞控制器
        for lostPacket in lostPackets {
            congestionController.onPacketLost(packet: lostPacket)
        }
        
        // 触发拥塞事件
        congestionController.onCongestionEvent()
        
        // 通知代理
        delegate?.lossAndCongestionManager(self, didDetectPacketLoss: lostPackets)
    }
    
    // MARK: - 发送控制
    
    public func canSend(bytes: UInt64) -> Bool {
        return congestionController.canSend(bytes: bytes)
    }
    
    public var availableWindow: UInt64 {
        let congestionWindow = congestionController.congestionWindow
        let bytesInFlight = congestionController.bytesInFlight
        return congestionWindow > bytesInFlight ? congestionWindow - bytesInFlight : 0
    }
    
    // MARK: - 状态查询
    
    public var congestionWindow: UInt64 {
        return congestionController.congestionWindow
    }
    
    public var bytesInFlight: UInt64 {
        return congestionController.bytesInFlight
    }
    
    public var smoothedRTT: TimeInterval {
        return lossDetector.smoothedRTT
    }
    
    public var minRTT: TimeInterval {
        return lossDetector.minRTT
    }
    
    public var retransmissionTimeout: TimeInterval {
        return lossDetector.retransmissionTimeout
    }
    
    public var pendingPacketCount: Int {
        return lossDetector.pendingPacketCount
    }
    
    // MARK: - 统计信息
    
    public func getStatistics() -> [String: Any] {
        var stats = congestionController.getStatistics()
        let lossStats = lossDetector.getStatistics()
        
        // 合并统计信息
        for (key, value) in lossStats {
            stats[key] = value
        }
        
        // 添加管理器特有的统计信息
        stats["total_packets_sent"] = totalPacketsSent
        stats["total_packets_lost"] = totalPacketsLost
        stats["total_packets_acked"] = totalPacketsAcked
        stats["total_congestion_events"] = totalCongestionEvents
        stats["loss_rate"] = calculateLossRate()
        stats["delivery_rate"] = calculateDeliveryRate()
        
        return stats
    }
    
    private func calculateLossRate() -> Double {
        guard totalPacketsSent > 0 else { return 0.0 }
        return Double(totalPacketsLost) / Double(totalPacketsSent)
    }
    
    private func calculateDeliveryRate() -> Double {
        guard totalPacketsSent > 0 else { return 0.0 }
        return Double(totalPacketsAcked) / Double(totalPacketsSent)
    }
    
    // MARK: - 重置和调试
    
    public func reset() {
        totalPacketsSent = 0
        totalPacketsLost = 0
        totalPacketsAcked = 0
        totalCongestionEvents = 0
    }
}

// MARK: - 丢包检测器代理实现
extension LossAndCongestionManager: LossDetectionDelegate {
    public func lossDetector(_ detector: LossDetector, didDetectLoss lostPackets: [LostPacket]) {
        // 这个方法会通过定时器调用，处理基于时间的丢包
        handlePacketLoss(lostPackets)
    }
    
    public func lossDetector(_ detector: LossDetector, didUpdateRTT samples: [RTTSample]) {
        // RTT更新通知，可以用于额外的处理
        delegate?.lossAndCongestionManager(self, didUpdateRTT: samples)
    }
}

// MARK: - 代理协议
public protocol LossAndCongestionDelegate: AnyObject {
    func lossAndCongestionManager(_ manager: LossAndCongestionManager, didSendPacket packet: SentPacket)
    func lossAndCongestionManager(_ manager: LossAndCongestionManager, didAcknowledgePackets packets: [AckedPacket], withLostPackets lostPackets: [LostPacket])
    func lossAndCongestionManager(_ manager: LossAndCongestionManager, didDetectPacketLoss lostPackets: [LostPacket])
    func lossAndCongestionManager(_ manager: LossAndCongestionManager, didUpdateRTT samples: [RTTSample])
}

// MARK: - 工厂方法
extension LossAndCongestionManager {
    public static func createWithNewReno(initialWindow: UInt64? = nil) -> LossAndCongestionManager {
        let lossDetector = LossDetector()
        let congestionController = NewRenoCongestionController(initialWindow: initialWindow)
        return LossAndCongestionManager(lossDetector: lossDetector, congestionController: congestionController)
    }
    
    public static func createWithEnhancedNewReno(initialWindow: UInt64? = nil) -> LossAndCongestionManager {
        let lossDetector = LossDetector()
        let congestionController = EnhancedNewRenoCongestionController(initialWindow: initialWindow)
        return LossAndCongestionManager(lossDetector: lossDetector, congestionController: congestionController)
    }
}

// MARK: - 扩展功能
extension LossAndCongestionManager {
    
    /// 批量处理包确认，提高性能
    public func processBatchAcknowledgment(packets: [(sent: SentPacket, acked: AckedPacket)]) {
        let ackedPackets = packets.map { $0.acked }
        onPacketAcknowledged(ackedPackets: ackedPackets)
    }
    
    /// 获取发送建议
    public func getSendingRecommendation() -> SendingRecommendation {
        let availableBytes = availableWindow
        let congestionState = (congestionController as? NewRenoCongestionController)?.currentState ?? .slowStart
        
        return SendingRecommendation(
            canSendBytes: availableBytes,
            recommendedPacketSize: min(1200, availableBytes), // MSS或可用窗口
            congestionState: congestionState,
            rtt: smoothedRTT,
            lossRate: calculateLossRate()
        )
    }
    
    /// 检查是否应该限制发送
    public func shouldThrottle() -> Bool {
        // 如果丢包率过高或窗口很小，建议限制发送
        let lossRate = calculateLossRate()
        let windowUtilization = Double(bytesInFlight) / Double(congestionWindow)
        
        return lossRate > 0.05 || windowUtilization > 0.9 // 丢包率>5%或窗口利用率>90%
    }
}

// MARK: - 发送建议结构
public struct SendingRecommendation {
    public let canSendBytes: UInt64
    public let recommendedPacketSize: UInt64
    public let congestionState: CongestionState
    public let rtt: TimeInterval
    public let lossRate: Double
    
    public var shouldSend: Bool {
        return canSendBytes > 0
    }
    
    public var priority: SendingPriority {
        if lossRate > 0.1 {
            return .low
        } else if congestionState == .slowStart {
            return .high
        } else {
            return .medium
        }
    }
}

public enum SendingPriority {
    case low
    case medium
    case high
}