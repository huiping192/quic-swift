import XCTest
@testable import QUICSwift

// Mock连接类用于测试
class MockQUICConnection: QUICConnectionProtocol {
    let connectionID: ConnectionID
    var receivedPackets: [QUICPacket] = []
    
    init(connectionID: ConnectionID) {
        self.connectionID = connectionID
    }
    
    func handlePacket(_ packet: QUICPacket) async throws {
        receivedPackets.append(packet)
    }
}

final class ConnectionIDManagerTests: XCTestCase {
    var manager: ConnectionIDManager!
    
    override func setUp() {
        super.setUp()
        manager = ConnectionIDManager()
    }
    
    override func tearDown() {
        manager = nil
        super.tearDown()
    }
    
    func testConnectionIDGeneration() {
        let id1 = manager.generateConnectionID()
        let id2 = manager.generateConnectionID()
        
        XCTAssertNotEqual(id1, id2)
        XCTAssertGreaterThanOrEqual(id1.length, 8)
        XCTAssertLessThanOrEqual(id1.length, 20)
        XCTAssertGreaterThanOrEqual(id2.length, 8)
        XCTAssertLessThanOrEqual(id2.length, 20)
    }
    
    func testConnectionRegistration() throws {
        let connectionID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let connection = MockQUICConnection(connectionID: connectionID)
        
        try manager.registerConnection(id: connectionID, connection: connection)
        
        let stats = manager.getStatistics()
        XCTAssertEqual(stats.activeConnections, 1)
        XCTAssertEqual(stats.totalRegistered, 1)
    }
    
    func testConnectionRegistrationCollision() throws {
        let connectionID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let connection1 = MockQUICConnection(connectionID: connectionID)
        let connection2 = MockQUICConnection(connectionID: connectionID)
        
        try manager.registerConnection(id: connectionID, connection: connection1)
        
        XCTAssertThrowsError(try manager.registerConnection(id: connectionID, connection: connection2)) { error in
            XCTAssertEqual(error as? QUICError, .connectionIDCollision)
        }
    }
    
    func testConnectionUnregistration() throws {
        let connectionID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let connection = MockQUICConnection(connectionID: connectionID)
        
        try manager.registerConnection(id: connectionID, connection: connection)
        XCTAssertEqual(manager.getStatistics().activeConnections, 1)
        
        manager.unregisterConnection(id: connectionID)
        XCTAssertEqual(manager.getStatistics().activeConnections, 0)
    }
    
    func testPacketRouting() throws {
        let connectionID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let connection = MockQUICConnection(connectionID: connectionID)
        
        try manager.registerConnection(id: connectionID, connection: connection)
        
        let packet = QUICPacket(
            headerForm: .long,
            packetType: .initial,
            version: QUICVersion.current,
            destinationConnectionID: connectionID,
            sourceConnectionID: nil,
            packetNumber: 0,
            payload: Data([0xAA])
        )
        
        let routedConnection = manager.routePacket(packet)
        XCTAssertNotNil(routedConnection)
        XCTAssertTrue(routedConnection === connection)
    }
    
    func testPacketRoutingNoMatch() {
        let unknownConnectionID = ConnectionID(bytes: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        
        let packet = QUICPacket(
            headerForm: .long,
            packetType: .initial,
            version: QUICVersion.current,
            destinationConnectionID: unknownConnectionID,
            sourceConnectionID: nil,
            packetNumber: 0,
            payload: Data([0xAA])
        )
        
        let routedConnection = manager.routePacket(packet)
        XCTAssertNil(routedConnection)
    }
    
    func testConnectionIDValidation() {
        let validID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertTrue(manager.validateConnectionID(validID))
        
        let emptyID = ConnectionID.empty
        XCTAssertTrue(manager.validateConnectionID(emptyID))
        
        // 测试长度超限的ID（这在ConnectionID初始化时就会失败，所以这里测试最大长度）
        let maxLengthBytes = Data(repeating: 0x00, count: Int(ConnectionID.maxLength))
        let maxLengthID = ConnectionID(bytes: maxLengthBytes)
        XCTAssertTrue(manager.validateConnectionID(maxLengthID))
    }
    
    func testConnectionIDRetirement() throws {
        let connectionID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let connection = MockQUICConnection(connectionID: connectionID)
        
        try manager.registerConnection(id: connectionID, connection: connection)
        XCTAssertTrue(manager.isConnectionIDInUse(connectionID))
        
        manager.retireConnectionID(connectionID)
        
        XCTAssertTrue(manager.isConnectionIDInUse(connectionID)) // 仍在已退役列表中
        XCTAssertFalse(manager.validateConnectionID(connectionID)) // 但验证失败
        
        let stats = manager.getStatistics()
        XCTAssertEqual(stats.activeConnections, 0)
        XCTAssertEqual(stats.retiredIDs, 1)
    }
    
    func testRetiredConnectionIDReuse() throws {
        let connectionID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let connection1 = MockQUICConnection(connectionID: connectionID)
        let connection2 = MockQUICConnection(connectionID: connectionID)
        
        try manager.registerConnection(id: connectionID, connection: connection1)
        manager.retireConnectionID(connectionID)
        
        XCTAssertThrowsError(try manager.registerConnection(id: connectionID, connection: connection2)) { error in
            if case .protocolViolation(let message) = error as? QUICError {
                XCTAssertTrue(message.contains("retired"))
            } else {
                XCTFail("Expected protocolViolation error about retired connection ID")
            }
        }
    }
    
    func testWeakReferenceCleanup() throws {
        let connectionID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        
        do {
            let connection = MockQUICConnection(connectionID: connectionID)
            try manager.registerConnection(id: connectionID, connection: connection)
            XCTAssertEqual(manager.getStatistics().activeConnections, 1)
        } // connection被释放
        
        // 强制清理
        manager.forceCleanup()
        
        // 连接应该被自动清理
        XCTAssertEqual(manager.getStatistics().activeConnections, 0)
        
        // 路由应该返回nil
        let packet = QUICPacket(
            headerForm: .long,
            packetType: .initial,
            version: QUICVersion.current,
            destinationConnectionID: connectionID,
            sourceConnectionID: nil,
            packetNumber: 0,
            payload: Data([0xAA])
        )
        
        XCTAssertNil(manager.routePacket(packet))
    }
    
    func testConnectionSearch() throws {
        let id1 = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let id2 = ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let connection1 = MockQUICConnection(connectionID: id1)
        let connection2 = MockQUICConnection(connectionID: id2)
        
        // 给connection1添加一些包用于测试
        connection1.receivedPackets.append(QUICPacket(
            headerForm: .long,
            packetType: .initial,
            version: QUICVersion.current,
            destinationConnectionID: id1,
            sourceConnectionID: nil,
            packetNumber: 0,
            payload: Data([0xAA])
        ))
        
        try manager.registerConnection(id: id1, connection: connection1)
        try manager.registerConnection(id: id2, connection: connection2)
        
        // 查找有接收包的连接
        let connectionsWithPackets = manager.findConnections { connection in
            guard let mockConnection = connection as? MockQUICConnection else { return false }
            return !mockConnection.receivedPackets.isEmpty
        }
        
        XCTAssertEqual(connectionsWithPackets.count, 1)
        XCTAssertTrue(connectionsWithPackets.first === connection1)
    }
    
    func testConnectionCount() throws {
        XCTAssertEqual(manager.getConnectionCount(), 0)
        
        let id1 = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let id2 = ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let connection1 = MockQUICConnection(connectionID: id1)
        let connection2 = MockQUICConnection(connectionID: id2)
        
        try manager.registerConnection(id: id1, connection: connection1)
        XCTAssertEqual(manager.getConnectionCount(), 1)
        
        try manager.registerConnection(id: id2, connection: connection2)
        XCTAssertEqual(manager.getConnectionCount(), 2)
        
        manager.unregisterConnection(id: id1)
        XCTAssertEqual(manager.getConnectionCount(), 1)
    }
    
    func testActiveAndRetiredConnectionIDs() throws {
        let activeID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let retiredID = ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        
        let connection1 = MockQUICConnection(connectionID: activeID)
        let connection2 = MockQUICConnection(connectionID: retiredID)
        
        try manager.registerConnection(id: activeID, connection: connection1)
        try manager.registerConnection(id: retiredID, connection: connection2)
        
        manager.retireConnectionID(retiredID)
        
        let activeIDs = manager.getAllActiveConnectionIDs()
        let retiredIDs = manager.getAllRetiredConnectionIDs()
        
        XCTAssertTrue(activeIDs.contains(activeID))
        XCTAssertFalse(activeIDs.contains(retiredID))
        XCTAssertFalse(retiredIDs.contains(activeID))
        XCTAssertTrue(retiredIDs.contains(retiredID))
    }
    
    func testDebugInfo() throws {
        let connectionID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let connection = MockQUICConnection(connectionID: connectionID)
        
        let emptyDebugInfo = manager.debugInfo()
        XCTAssertTrue(emptyDebugInfo.contains("Active Connections: 0"))
        
        try manager.registerConnection(id: connectionID, connection: connection)
        manager.retireConnectionID(connectionID)
        
        let debugInfo = manager.debugInfo()
        XCTAssertTrue(debugInfo.contains("Active Connections: 0"))
        XCTAssertTrue(debugInfo.contains("Retired IDs: 1"))
        XCTAssertTrue(debugInfo.contains("01020304"))
    }
}