import Foundation

// MARK: - 拥塞控制协议
public protocol CongestionController {
    var congestionWindow: UInt64 { get }
    var slowStartThreshold: UInt64 { get }
    var bytesInFlight: UInt64 { get }
    
    func onPacketSent(packet: SentPacket)
    func onPacketAcked(packet: AckedPacket, rtt: TimeInterval)
    func onPacketLost(packet: LostPacket)
    func onCongestionEvent()
    func canSend(bytes: UInt64) -> Bool
    
    // 获取当前状态信息
    func getStatistics() -> [String: Any]
}

// MARK: - 拥塞控制状态
public enum CongestionState {
    case slowStart      // 慢启动
    case congestionAvoidance  // 拥塞避免
    case fastRecovery   // 快速恢复
}

// MARK: - NewReno拥塞控制实现
public class NewRenoCongestionController: CongestionController {
    // 算法参数
    private let maxSegmentSize: UInt64 = 1200  // 最大段大小
    private let initialWindow: UInt64          // 初始窗口大小
    private let minWindow: UInt64 = 2400       // 最小窗口大小（2 * MSS）
    
    // 状态变量
    private(set) public var congestionWindow: UInt64
    private(set) public var slowStartThreshold: UInt64
    private(set) public var bytesInFlight: UInt64 = 0
    private var state: CongestionState = .slowStart
    
    // 快速恢复相关
    private var fastRecoveryExitPoint: UInt64 = 0
    private var duplicateAckCount: Int = 0
    private var lastAckedPacket: UInt64 = 0
    
    // 统计信息
    private var totalBytesSent: UInt64 = 0
    private var totalBytesAcked: UInt64 = 0
    private var congestionEvents: Int = 0
    private var maxCongestionWindow: UInt64 = 0
    
    public init(initialWindow: UInt64? = nil) {
        self.initialWindow = initialWindow ?? (10 * maxSegmentSize)
        self.congestionWindow = self.initialWindow
        self.slowStartThreshold = UInt64.max
        self.maxCongestionWindow = self.congestionWindow
    }
    
    // MARK: - 包发送处理
    
    public func onPacketSent(packet: SentPacket) {
        bytesInFlight += UInt64(packet.size)
        totalBytesSent += UInt64(packet.size)
    }
    
    // MARK: - 包确认处理
    
    public func onPacketAcked(packet: AckedPacket, rtt: TimeInterval) {
        bytesInFlight -= UInt64(packet.size)
        totalBytesAcked += UInt64(packet.size)
        
        // 检测重复ACK
        if packet.packetNumber == lastAckedPacket {
            duplicateAckCount += 1
            if duplicateAckCount >= 3 && state != .fastRecovery {
                // 进入快速恢复
                enterFastRecovery()
                return
            }
        } else if packet.packetNumber > lastAckedPacket {
            // 新的ACK，重置重复计数
            lastAckedPacket = packet.packetNumber
            duplicateAckCount = 0
            
            // 如果在快速恢复中且ACK超过了退出点，退出快速恢复
            if state == .fastRecovery && packet.packetNumber >= fastRecoveryExitPoint {
                exitFastRecovery()
            }
        }
        
        // 根据当前状态调整拥塞窗口
        switch state {
        case .slowStart:
            handleSlowStartAck(packet)
        case .congestionAvoidance:
            handleCongestionAvoidanceAck(packet)
        case .fastRecovery:
            handleFastRecoveryAck(packet)
        }
        
        // 更新最大窗口记录
        maxCongestionWindow = max(maxCongestionWindow, congestionWindow)
    }
    
    private func handleSlowStartAck(_ packet: AckedPacket) {
        // 慢启动：每个ACK增加一个MSS
        congestionWindow += UInt64(packet.size)
        
        // 检查是否应该退出慢启动
        if congestionWindow >= slowStartThreshold {
            state = .congestionAvoidance
        }
    }
    
    private func handleCongestionAvoidanceAck(_ packet: AckedPacket) {
        // 拥塞避免：每个RTT增加一个MSS
        // 使用加性增加：cwnd += MSS * MSS / cwnd
        let increment = maxSegmentSize * UInt64(packet.size) / congestionWindow
        congestionWindow += max(1, increment)
    }
    
    private func handleFastRecoveryAck(_ packet: AckedPacket) {
        // 快速恢复：保持窗口大小，等待退出条件
        // 这里可以实现窗口膨胀（inflate window）如果需要的话
    }
    
    // MARK: - 包丢失处理
    
    public func onPacketLost(packet: LostPacket) {
        bytesInFlight -= UInt64(packet.size)
        
        // 只有在不处于快速恢复状态时才触发拥塞事件
        if state != .fastRecovery {
            onCongestionEvent()
        }
    }
    
    public func onCongestionEvent() {
        congestionEvents += 1
        
        // 进入快速恢复状态
        if state != .fastRecovery {
            enterFastRecovery()
        }
    }
    
    private func enterFastRecovery() {
        state = .fastRecovery
        
        // 设置慢启动阈值为当前窗口的一半
        slowStartThreshold = max(congestionWindow / 2, minWindow)
        
        // 将拥塞窗口设置为慢启动阈值
        congestionWindow = slowStartThreshold
        
        // 设置快速恢复退出点为当前最后确认的包号
        fastRecoveryExitPoint = lastAckedPacket + 1
    }
    
    private func exitFastRecovery() {
        state = .congestionAvoidance
        
        // 将拥塞窗口设置为慢启动阈值
        congestionWindow = slowStartThreshold
    }
    
    // MARK: - 发送控制
    
    public func canSend(bytes: UInt64) -> Bool {
        return bytesInFlight + bytes <= congestionWindow
    }
    
    // MARK: - 统计信息
    
    public func getStatistics() -> [String: Any] {
        return [
            "congestion_window": congestionWindow,
            "slow_start_threshold": slowStartThreshold,
            "bytes_in_flight": bytesInFlight,
            "state": stateDescription,
            "total_bytes_sent": totalBytesSent,
            "total_bytes_acked": totalBytesAcked,
            "congestion_events": congestionEvents,
            "max_congestion_window": maxCongestionWindow,
            "duplicate_ack_count": duplicateAckCount,
            "utilization": calculateUtilization()
        ]
    }
    
    private var stateDescription: String {
        switch state {
        case .slowStart: return "Slow Start"
        case .congestionAvoidance: return "Congestion Avoidance"
        case .fastRecovery: return "Fast Recovery"
        }
    }
    
    private func calculateUtilization() -> Double {
        guard congestionWindow > 0 else { return 0.0 }
        return Double(bytesInFlight) / Double(congestionWindow)
    }
    
    // MARK: - 调试和监控
    
    public func reset() {
        congestionWindow = initialWindow
        slowStartThreshold = UInt64.max
        bytesInFlight = 0
        state = .slowStart
        duplicateAckCount = 0
        lastAckedPacket = 0
        fastRecoveryExitPoint = 0
    }
    
    public var currentState: CongestionState {
        return state
    }
    
    public var isInSlowStart: Bool {
        return state == .slowStart
    }
    
    public var isInFastRecovery: Bool {
        return state == .fastRecovery
    }
}

// MARK: - 拥塞控制器工厂
public class CongestionControllerFactory {
    public enum Algorithm {
        case newReno
        // 未来可以添加其他算法
        // case cubic
        // case bbr
    }
    
    public static func create(_ algorithm: Algorithm, initialWindow: UInt64? = nil) -> CongestionController {
        switch algorithm {
        case .newReno:
            return NewRenoCongestionController(initialWindow: initialWindow)
        }
    }
}

// MARK: - 拥塞控制代理协议
public protocol CongestionControlDelegate: AnyObject {
    func congestionController(_ controller: CongestionController, didChangeWindow newWindow: UInt64)
    func congestionController(_ controller: CongestionController, didEnterState state: CongestionState)
    func congestionController(_ controller: CongestionController, didDetectCongestion event: String)
}

// MARK: - 增强的拥塞控制器（支持代理）
public class EnhancedNewRenoCongestionController: NewRenoCongestionController {
    public weak var delegate: CongestionControlDelegate?
    private var lastReportedWindow: UInt64 = 0
    
    public override func onPacketAcked(packet: AckedPacket, rtt: TimeInterval) {
        let oldState = currentState
        let oldWindow = congestionWindow
        
        super.onPacketAcked(packet: packet, rtt: rtt)
        
        // 报告状态变化
        if currentState != oldState {
            delegate?.congestionController(self, didEnterState: currentState)
        }
        
        // 报告窗口变化（避免频繁通知）
        if abs(Int64(congestionWindow) - Int64(lastReportedWindow)) >= 1200 {
            delegate?.congestionController(self, didChangeWindow: congestionWindow)
            lastReportedWindow = congestionWindow
        }
    }
    
    public override func onCongestionEvent() {
        super.onCongestionEvent()
        delegate?.congestionController(self, didDetectCongestion: "Packet loss detected")
        delegate?.congestionController(self, didEnterState: currentState)
    }
}