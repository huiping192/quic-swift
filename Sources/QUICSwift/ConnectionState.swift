import Foundation

public enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case closing
    case closed
    case failed(Error)
    
    public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.connecting, .connecting),
             (.connected, .connected),
             (.closing, .closing),
             (.closed, .closed):
            return true
        case (.failed, .failed):
            return true
        default:
            return false
        }
    }
    
    public var isConnected: Bool {
        return self == .connected
    }
    
    public var canSend: Bool {
        return self == .connected
    }
    
    public var canReceive: Bool {
        return self == .connected || self == .closing
    }
}

public enum ConnectionEvent {
    case startConnecting
    case connectionEstablished
    case connectionFailed(Error)
    case startClosing
    case connectionClosed
    case reset
}

public class ConnectionStateMachine {
    private var _state: ConnectionState = .idle
    private let stateQueue = DispatchQueue(label: "connection.state", qos: .userInitiated)
    
    public var state: ConnectionState {
        return stateQueue.sync { _state }
    }
    
    public var onStateChange: ((ConnectionState, ConnectionState) -> Void)?
    
    public func transition(event: ConnectionEvent) -> Bool {
        return stateQueue.sync {
            let oldState = _state
            let newState = nextState(from: oldState, event: event)
            
            guard newState != oldState else {
                return false
            }
            
            _state = newState
            onStateChange?(oldState, newState)
            return true
        }
    }
    
    private func nextState(from currentState: ConnectionState, event: ConnectionEvent) -> ConnectionState {
        switch (currentState, event) {
        case (.idle, .startConnecting):
            return .connecting
        case (.connecting, .connectionEstablished):
            return .connected
        case (.connecting, .connectionFailed(let error)):
            return .failed(error)
        case (.connected, .startClosing):
            return .closing
        case (.connected, .connectionFailed(let error)):
            return .failed(error)
        case (.closing, .connectionClosed):
            return .closed
        case (_, .reset):
            return .closed
        default:
            return currentState
        }
    }
}