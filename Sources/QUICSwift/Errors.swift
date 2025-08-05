import Foundation

public enum NetworkError: Error, LocalizedError, Equatable {
    case notConnected
    case connectionClosed
    case invalidEndpoint
    case sendTimeout
    case receiveTimeout
    case bindFailed(String)
    case listenerFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Connection not established"
        case .connectionClosed:
            return "Connection has been closed"
        case .invalidEndpoint:
            return "Invalid network endpoint"
        case .sendTimeout:
            return "Send operation timed out"
        case .receiveTimeout:
            return "Receive operation timed out"
        case .bindFailed(let reason):
            return "Failed to bind to address: \(reason)"
        case .listenerFailed(let reason):
            return "Listener failed: \(reason)"
        }
    }
}

public enum ParsingError: Error, LocalizedError {
    case insufficientData
    case invalidVariableInt
    case malformedPacket
    case unsupportedVersion
    case invalidOffset
    case bufferOverflow
    
    public var errorDescription: String? {
        switch self {
        case .insufficientData:
            return "Insufficient data for parsing"
        case .invalidVariableInt:
            return "Invalid variable integer encoding"
        case .malformedPacket:
            return "Malformed packet structure"
        case .unsupportedVersion:
            return "Unsupported protocol version"
        case .invalidOffset:
            return "Invalid data offset"
        case .bufferOverflow:
            return "Buffer overflow detected"
        }
    }
}

public enum ConnectionError: Error, LocalizedError, Equatable {
    case invalidState
    case handshakeFailed
    case protocolViolation(String)
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .invalidState:
            return "Invalid connection state"
        case .handshakeFailed:
            return "Handshake failed"
        case .protocolViolation(let reason):
            return "Protocol violation: \(reason)"
        case .timeout:
            return "Operation timed out"
        }
    }
}