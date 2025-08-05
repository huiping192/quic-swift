import XCTest
import Network
@testable import QUICSwift

final class IntegrationTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // 设置测试超时时间
        continueAfterFailure = false
    }
    
    func testUDPConnectionBasicFlow() async throws {
        let connection = UDPConnection()
        
        // 测试初始状态
        XCTAssertEqual(connection.state, .idle)
        
        // 创建本地端点进行测试
        let port = NWEndpoint.Port(rawValue: 0)! // 随机端口
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        
        // 注意：这个测试可能会失败，因为没有实际的服务器在监听
        // 在实际使用中，你需要确保有服务器在运行
        do {
            try await connection.connect(to: endpoint)
            XCTFail("Expected connection to fail without a server")
        } catch {
            // 预期的错误，因为没有服务器在监听
            // 预期会有错误，因为没有服务器监听
            XCTAssertNotNil(error)
        }
        
        connection.close()
        XCTAssertEqual(connection.state, .closed)
    }
    
    func testPacketParserIntegration() throws {
        // 创建一个模拟的QUIC包数据
        var builder = PacketBuilder()
        
        // 模拟包头
        builder.writeUInt8(0x80) // 长包头标志
        builder.writeUInt32(0x00000001) // 版本
        builder.writeUInt8(0x88) // 连接ID长度 (8+8)
        
        // 目标连接ID
        let destCID = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        builder.writeBytes(destCID)
        
        // 源连接ID
        let srcCID = Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        builder.writeBytes(srcCID)
        
        // 包长度
        builder.writeVariableInt(100)
        
        // 包号
        builder.writeUInt32(0x12345678)
        
        // 载荷
        let payload = Data(repeating: 0xAA, count: 64)
        builder.writeBytes(payload)
        
        let packetData = builder.build()
        
        // 解析包
        var parser = PacketParser(data: packetData)
        
        let headerForm = try parser.readUInt8()
        XCTAssertEqual(headerForm & 0x80, 0x80) // 长包头
        
        let version = try parser.readUInt32()
        XCTAssertEqual(version, 0x00000001)
        
        let cidLengths = try parser.readUInt8()
        XCTAssertEqual(cidLengths, 0x88)
        
        let parsedDestCID = try parser.readBytes(count: 8)
        XCTAssertEqual(parsedDestCID, destCID)
        
        let parsedSrcCID = try parser.readBytes(count: 8)
        XCTAssertEqual(parsedSrcCID, srcCID)
        
        let length = try parser.readVariableInt()
        XCTAssertEqual(length, 100)
        
        let packetNumber = try parser.readUInt32()
        XCTAssertEqual(packetNumber, 0x12345678)
    }
    
    func testConnectionStateMachineIntegration() {
        let stateMachine = ConnectionStateMachine()
        var stateHistory: [ConnectionState] = []
        
        // 记录状态变化
        stateMachine.onStateChange = { _, newState in
            stateHistory.append(newState)
        }
        
        // 模拟完整的连接流程
        XCTAssertTrue(stateMachine.transition(event: .startConnecting))
        XCTAssertTrue(stateMachine.transition(event: .connectionEstablished))
        XCTAssertTrue(stateMachine.transition(event: .startClosing))
        XCTAssertTrue(stateMachine.transition(event: .connectionClosed))
        
        // 验证状态历史
        let expectedStates: [ConnectionState] = [
            .connecting,
            .connected,
            .closing,
            .closed
        ]
        
        XCTAssertEqual(stateHistory.count, expectedStates.count)
        for (actual, expected) in zip(stateHistory, expectedStates) {
            XCTAssertEqual(actual, expected)
        }
    }
    
    func testErrorHandlingIntegration() {
        func processData(_ data: Data) throws -> String {
            guard !data.isEmpty else {
                throw ParsingError.insufficientData
            }
            
            var parser = PacketParser(data: data)
            
            // 尝试读取一个字符串长度
            let length = try parser.readUInt8()
            guard length > 0 else {
                throw ParsingError.malformedPacket
            }
            
            // 尝试读取字符串数据
            let stringData = try parser.readBytes(count: Int(length))
            guard let string = String(data: stringData, encoding: .utf8) else {
                throw ParsingError.malformedPacket
            }
            
            return string
        }
        
        // 测试正常情况
        let validData = Data([5]) + "Hello".data(using: .utf8)!
        XCTAssertNoThrow(try processData(validData))
        XCTAssertEqual(try processData(validData), "Hello")
        
        // 测试错误情况
        XCTAssertThrowsError(try processData(Data())) { error in
            XCTAssertEqual(error as? ParsingError, .insufficientData)
        }
        
        XCTAssertThrowsError(try processData(Data([0]))) { error in
            XCTAssertEqual(error as? ParsingError, .malformedPacket)
        }
        
        XCTAssertThrowsError(try processData(Data([10, 65]))) { error in
            XCTAssertEqual(error as? ParsingError, .insufficientData)
        }
    }
    
    func testConcurrentPacketProcessing() async throws {
        let iterations = 100
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for i in 0..<iterations {
                group.addTask {
                    do {
                        // 创建包数据
                        var builder = PacketBuilder()
                        builder.writeUInt32(UInt32(i))
                        builder.writeVariableInt(UInt64(i * 2))
                        
                        let data = builder.build()
                        
                        // 解析包数据
                        var parser = PacketParser(data: data)
                        let value1 = try parser.readUInt32()
                        let value2 = try parser.readVariableInt()
                        
                        return value1 == UInt32(i) && value2 == UInt64(i * 2)
                    } catch {
                        return false
                    }
                }
            }
            
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        // 所有任务都应该成功
        XCTAssertEqual(results.count, iterations)
        XCTAssertTrue(results.allSatisfy { $0 })
    }
    
    func testMemoryLeakPrevention() {
        // 创建多个连接并确保它们被正确释放
        weak var weakConnection: UDPConnection?
        
        autoreleasepool {
            let connection = UDPConnection()
            weakConnection = connection
            
            // 模拟一些操作
            connection.close()
        }
        
        // 强制垃圾回收
        autoreleasepool {
            // 连接应该被释放
        }
        
        XCTAssertNil(weakConnection, "UDPConnection should be deallocated")
    }
}