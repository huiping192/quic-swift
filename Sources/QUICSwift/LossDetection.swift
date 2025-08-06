import Foundation

// MARK: - 发送包信息
public struct SentPacket {
    public let packetNumber: UInt64
    public let sentTime: Date
    public let size: Int
    public let packetSpace: PacketNumberSpace
    public let frames: [Any] // 包含的帧信息
    public let isAckEliciting: Bool // 是否需要确认
    
    public init(packetNumber: UInt64, sentTime: Date, size: Int, 
                packetSpace: PacketNumberSpace, frames: [Any], isAckEliciting: Bool) {
        self.packetNumber = packetNumber
        self.sentTime = sentTime
        self.size = size
        self.packetSpace = packetSpace
        self.frames = frames
        self.isAckEliciting = isAckEliciting
    }
}

// MARK: - 确认包信息
public struct AckedPacket {
    public let packetNumber: UInt64
    public let sentTime: Date
    public let size: Int
    public let ackedTime: Date
    public let packetSpace: PacketNumberSpace
    
    public init(packetNumber: UInt64, sentTime: Date, size: Int, 
                ackedTime: Date, packetSpace: PacketNumberSpace) {
        self.packetNumber = packetNumber
        self.sentTime = sentTime
        self.size = size
        self.ackedTime = ackedTime
        self.packetSpace = packetSpace
    }
    
    public var rtt: TimeInterval {
        return ackedTime.timeIntervalSince(sentTime)
    }
}

// MARK: - 丢失包信息
public struct LostPacket {
    public let packetNumber: UInt64
    public let sentTime: Date
    public let size: Int
    public let frames: [Any]
    public let packetSpace: PacketNumberSpace
    public let lostTime: Date
    
    public init(packetNumber: UInt64, sentTime: Date, size: Int, 
                frames: [Any], packetSpace: PacketNumberSpace, lostTime: Date) {
        self.packetNumber = packetNumber
        self.sentTime = sentTime
        self.size = size
        self.frames = frames
        self.packetSpace = packetSpace
        self.lostTime = lostTime
    }
}

// MARK: - RTT样本
public struct RTTSample {
    public let rtt: TimeInterval
    public let ackDelay: TimeInterval
    public let sampleTime: Date
    
    public init(rtt: TimeInterval, ackDelay: TimeInterval = 0, sampleTime: Date = Date()) {
        self.rtt = rtt
        self.ackDelay = ackDelay
        self.sampleTime = sampleTime
    }
    
    public var adjustedRTT: TimeInterval {
        return max(rtt - ackDelay, rtt / 8)
    }
}

// MARK: - 丢包检测方法
public enum LossDetectionMethod {
    case packetThreshold    // 基于包间隔的检测
    case timeThreshold      // 基于时间的检测  
    case earlyRetransmit    // 早期重传
    case tailLossProbe      // 尾部丢包探测
}

// MARK: - 丢包检测器
public class LossDetector {
    // 配置常量
    private let packetThreshold: Int = 3
    private let timeThreshold: Double = 9.0 / 8.0 // 1.125倍RTT
    private let granularity: TimeInterval = 0.001 // 1ms
    private let initialRTT: TimeInterval = 0.5 // 500ms初始RTT
    
    // 状态变量 - 使用复合key来支持不同包空间的相同包号
    private var sentPackets: [PacketKey: SentPacket] = [:]
    private var lossTimer: Timer?
    private var rttStats = RTTStatistics()
    public weak var delegate: LossDetectionDelegate?
    
    // 包的复合键，包含包号和包空间
    private struct PacketKey: Hashable {
        let packetNumber: UInt64
        let packetSpace: PacketNumberSpace
    }
    
    // RTT统计
    private class RTTStatistics {
        var smoothedRTT: TimeInterval = 0
        var rttVariation: TimeInterval = 0
        var minRTT: TimeInterval = TimeInterval.greatestFiniteMagnitude
        var latestRTT: TimeInterval = 0
        private let granularity: TimeInterval = 0.001 // 1ms
        
        func update(sample: RTTSample) {
            latestRTT = sample.adjustedRTT
            minRTT = min(minRTT, sample.rtt)
            
            if smoothedRTT == 0 {
                smoothedRTT = sample.adjustedRTT
                rttVariation = sample.adjustedRTT / 2
            } else {
                let alpha = 0.125
                let beta = 0.25
                
                rttVariation = (1 - beta) * rttVariation + beta * abs(smoothedRTT - sample.adjustedRTT)
                smoothedRTT = (1 - alpha) * smoothedRTT + alpha * sample.adjustedRTT
            }
        }
        
        var retransmissionTimeout: TimeInterval {
            if smoothedRTT == 0 {
                return 1.0 // 1秒默认RTO
            }
            return max(smoothedRTT + 4 * rttVariation, granularity)
        }
    }
    
    public init() {
        // 让RTT统计从0开始，由第一个样本初始化
        rttStats.smoothedRTT = 0
        rttStats.rttVariation = 0
    }
    
    // MARK: - 主要接口
    
    public func onPacketSent(_ packet: SentPacket) {
        let key = PacketKey(packetNumber: packet.packetNumber, packetSpace: packet.packetSpace)
        sentPackets[key] = packet
        setLossDetectionTimer()
    }
    
    public func onAckReceived(ackedPackets: [AckedPacket]) -> (lostPackets: [LostPacket], rttSamples: [RTTSample]) {
        var lostPackets: [LostPacket] = []
        var rttSamples: [RTTSample] = []
        
        // 更新RTT统计并移除已确认的包
        for ackedPacket in ackedPackets {
            let key = PacketKey(packetNumber: ackedPacket.packetNumber, packetSpace: ackedPacket.packetSpace)
            if let sentPacket = sentPackets[key] {
                let rttSample = RTTSample(
                    rtt: ackedPacket.rtt,
                    sampleTime: ackedPacket.ackedTime
                )
                rttSamples.append(rttSample)
                rttStats.update(sample: rttSample)
                
                // 移除已确认的包
                sentPackets.removeValue(forKey: key)
            }
        }
        
        // 检测丢包
        lostPackets = detectLoss(ackedPackets: ackedPackets)
        
        // 通知代理
        notifyDelegate(lostPackets: lostPackets, rttSamples: rttSamples)
        
        // 更新丢包检测定时器
        setLossDetectionTimer()
        
        return (lostPackets: lostPackets, rttSamples: rttSamples)
    }
    
    private func detectLoss(ackedPackets: [AckedPacket]) -> [LostPacket] {
        var lostPackets: [LostPacket] = []
        let now = Date()
        
        // 为每个包空间分别检测丢包
        for packetSpace in PacketNumberSpace.allCases {
            let spaceAckedPackets = ackedPackets.filter { $0.packetSpace == packetSpace }
            guard !spaceAckedPackets.isEmpty else { continue }
            
            let maxAckedInSpace = spaceAckedPackets.max(by: { $0.packetNumber < $1.packetNumber })!
            for (key, sentPacket) in sentPackets {
                guard sentPacket.packetSpace == packetSpace else { continue }
                var isLost = false
                
                // 基于包间隔的丢包检测 (RFC 9002)
                // 一个包被认为丢失，如果：
                // 1. 该包号小于最大已确认包号
                // 2. 最大已确认包号与该包号的差距 >= packetThreshold
                if key.packetNumber < maxAckedInSpace.packetNumber &&
                   maxAckedInSpace.packetNumber - key.packetNumber >= UInt64(packetThreshold) {
                    isLost = true
                }
                
                // 基于时间的丢包检测
                if !isLost {
                    let lossDelay = calculateLossDelay(for: sentPacket)
                    let timeSinceSent = now.timeIntervalSince(sentPacket.sentTime)
                    if timeSinceSent > lossDelay {
                        isLost = true
                    }
                }
                
                if isLost {
                    let lostPacket = LostPacket(
                        packetNumber: key.packetNumber,
                        sentTime: sentPacket.sentTime,
                        size: sentPacket.size,
                        frames: sentPacket.frames,
                        packetSpace: sentPacket.packetSpace,
                        lostTime: now
                    )
                    lostPackets.append(lostPacket)
                }
            }
        }
        
        // 移除丢失的包
        for lostPacket in lostPackets {
            let key = PacketKey(packetNumber: lostPacket.packetNumber, packetSpace: lostPacket.packetSpace)
            sentPackets.removeValue(forKey: key)
        }
        
        return lostPackets
    }
    
    private func calculateLossDelay(for packet: SentPacket) -> TimeInterval {
        // 如果还没有RTT样本，返回一个很大的值避免基于时间的误判
        if rttStats.smoothedRTT == 0 {
            return TimeInterval.greatestFiniteMagnitude
        }
        let maxRTT = max(rttStats.latestRTT, rttStats.smoothedRTT)
        return timeThreshold * maxRTT
    }
    
    private func setLossDetectionTimer() {
        lossTimer?.invalidate()
        lossTimer = nil
        
        guard !sentPackets.isEmpty else { return }
        
        // 找到最早的未确认包和对应的丢包延迟
        var earliestTimeout: TimeInterval?
        
        for (_, sentPacket) in sentPackets {
            let lossDelay = calculateLossDelay(for: sentPacket)
            let timeUntilLoss = lossDelay - Date().timeIntervalSince(sentPacket.sentTime)
            
            if timeUntilLoss > 0 {
                if earliestTimeout == nil || timeUntilLoss < earliestTimeout! {
                    earliestTimeout = timeUntilLoss
                }
            }
        }
        
        if let timeout = earliestTimeout {
            lossTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                self?.onLossDetectionTimeout()
            }
        }
    }
    
    private func onLossDetectionTimeout() {
        let lostPackets = detectTimeBasedLoss()
        
        // 通知上层处理丢包
        for lostPacket in lostPackets {
            // 这里应该通知拥塞控制器和重传机制
            handlePacketLoss(lostPacket)
        }
        
        // 重新设置定时器
        setLossDetectionTimer()
    }
    
    private func detectTimeBasedLoss() -> [LostPacket] {
        var lostPackets: [LostPacket] = []
        let now = Date()
        
        for (key, sentPacket) in sentPackets {
            let lossDelay = calculateLossDelay(for: sentPacket)
            let timeSinceSent = now.timeIntervalSince(sentPacket.sentTime)
            
            if timeSinceSent > lossDelay {
                let lostPacket = LostPacket(
                    packetNumber: key.packetNumber,
                    sentTime: sentPacket.sentTime,
                    size: sentPacket.size,
                    frames: sentPacket.frames,
                    packetSpace: sentPacket.packetSpace,
                    lostTime: now
                )
                lostPackets.append(lostPacket)
            }
        }
        
        // 移除丢失的包
        for lostPacket in lostPackets {
            let key = PacketKey(packetNumber: lostPacket.packetNumber, packetSpace: lostPacket.packetSpace)
            sentPackets.removeValue(forKey: key)
        }
        
        return lostPackets
    }
    
    private func handlePacketLoss(_ lostPacket: LostPacket) {
        // 这个方法将被重写以集成拥塞控制
        print("Package lost: \(lostPacket.packetNumber), space: \(lostPacket.packetSpace)")
    }
    
    // MARK: - 公共访问器
    
    public var smoothedRTT: TimeInterval {
        return rttStats.smoothedRTT
    }
    
    public var latestRTT: TimeInterval {
        return rttStats.latestRTT
    }
    
    public var minRTT: TimeInterval {
        return rttStats.minRTT == TimeInterval.greatestFiniteMagnitude ? 0 : rttStats.minRTT
    }
    
    public var retransmissionTimeout: TimeInterval {
        return rttStats.retransmissionTimeout
    }
    
    public var pendingPacketCount: Int {
        return sentPackets.count
    }
    
    // MARK: - 调试和监控
    
    public func getStatistics() -> [String: Any] {
        return [
            "smoothed_rtt": smoothedRTT,
            "latest_rtt": latestRTT,
            "min_rtt": minRTT,
            "rtt_variation": rttStats.rttVariation,
            "retransmission_timeout": retransmissionTimeout,
            "pending_packets": pendingPacketCount
        ]
    }
    
    private func notifyDelegate(lostPackets: [LostPacket], rttSamples: [RTTSample]) {
        if !lostPackets.isEmpty {
            delegate?.lossDetector(self, didDetectLoss: lostPackets)
        }
        if !rttSamples.isEmpty {
            delegate?.lossDetector(self, didUpdateRTT: rttSamples)
        }
    }
}

// MARK: - 协议用于集成
public protocol LossDetectionDelegate: AnyObject {
    func lossDetector(_ detector: LossDetector, didDetectLoss lostPackets: [LostPacket])
    func lossDetector(_ detector: LossDetector, didUpdateRTT samples: [RTTSample])
}