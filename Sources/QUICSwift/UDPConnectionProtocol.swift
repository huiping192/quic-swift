import Foundation
import Network

public protocol UDPConnectionProtocol {
    var state: ConnectionState { get }
    var onStateChange: ((ConnectionState, ConnectionState) -> Void)? { get set }
    var onDataReceived: ((Data, NWEndpoint?) -> Void)? { get set }
    
    func connect(to endpoint: NWEndpoint) async throws
    func send(data: Data) async throws
    func send(data: Data, to endpoint: NWEndpoint) async throws
    func receive() async throws -> (Data, NWEndpoint?)
    func close()
}

public protocol UDPListenerProtocol {
    var onNewConnection: ((UDPConnection) -> Void)? { get set }
    var onDataReceived: ((Data, NWEndpoint) -> Void)? { get set }
    
    func start(on port: UInt16) async throws
    func send(data: Data, to endpoint: NWEndpoint) async throws
    func stop()
}