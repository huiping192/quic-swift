import XCTest
@testable import QUICSwift

final class QUICStreamTests: XCTestCase {
    var stream: QUICStream!
    
    override func setUp() {
        super.setUp()
        stream = QUICStream(id: 0, type: .bidirectional, initialWindowSize: 65536)
    }
    
    override func tearDown() {
        stream = nil
        super.tearDown()
    }
    
    func testStreamInitialization() {
        XCTAssertEqual(stream.id, 0)
        XCTAssertEqual(stream.type, .bidirectional)
        XCTAssertEqual(stream.initiator, .client) // ID 0 是客户端发起的
        XCTAssertEqual(stream.state, .open)
        XCTAssertTrue(stream.isActive)
        XCTAssertFalse(stream.isClosed)
    }
    
    func testStreamTypeFromID() {
        XCTAssertEqual(StreamType.fromStreamID(0), .bidirectional)   // 0b00
        XCTAssertEqual(StreamType.fromStreamID(1), .bidirectional)   // 0b01
        XCTAssertEqual(StreamType.fromStreamID(2), .unidirectional)  // 0b10
        XCTAssertEqual(StreamType.fromStreamID(3), .unidirectional)  // 0b11
    }
    
    func testStreamInitiatorFromID() {
        XCTAssertEqual(StreamInitiator.fromStreamID(0), .client)  // 0b00
        XCTAssertEqual(StreamInitiator.fromStreamID(1), .server)  // 0b01
        XCTAssertEqual(StreamInitiator.fromStreamID(2), .client)  // 0b10
        XCTAssertEqual(StreamInitiator.fromStreamID(3), .server)  // 0b11
    }
    
    func testBasicWriteAndRead() async throws {
        let testData = "Hello, QUIC!".data(using: .utf8)!
        
        // 写入数据
        try await stream.write(data: testData)
        XCTAssertTrue(stream.hasDataToSend)
        
        // 模拟接收相同数据
        let frame = StreamFrame(streamID: stream.id, offset: 0, data: testData)
        try await stream.handleStreamFrame(frame)
        
        // 读取数据
        let readData = try await stream.read()
        XCTAssertEqual(readData, testData)
    }
    
    func testWriteWithoutBlocking() throws {
        let testData = "Test data".data(using: .utf8)!
        
        try stream.writeWithoutBlocking(data: testData)
        XCTAssertTrue(stream.hasDataToSend)
        
        let frame = stream.getDataToSend(maxBytes: 1000)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.data, testData)
        XCTAssertEqual(frame?.offset, 0)
        XCTAssertEqual(frame?.streamID, stream.id)
    }
    
    func testReadWithoutBlocking() async throws {
        let testData = "Test data".data(using: .utf8)!
        
        // 先发送数据给流
        let frame = StreamFrame(streamID: stream.id, offset: 0, data: testData)
        try await stream.handleStreamFrame(frame)
        
        // 非阻塞读取
        let readData = stream.readWithoutBlocking()
        XCTAssertEqual(readData, testData)
        
        // 再次读取应该返回nil
        let readData2 = stream.readWithoutBlocking()
        XCTAssertNil(readData2)
    }
    
    func testStreamFrameHandling() async throws {
        let data1 = "First chunk".data(using: .utf8)!
        let data2 = "Second chunk".data(using: .utf8)!
        
        // 按顺序发送帧
        let frame1 = StreamFrame(streamID: stream.id, offset: 0, data: data1)
        let frame2 = StreamFrame(streamID: stream.id, offset: UInt64(data1.count), data: data2)
        
        try await stream.handleStreamFrame(frame1)
        try await stream.handleStreamFrame(frame2)
        
        XCTAssertTrue(stream.hasPendingData)
        
        let readData1 = try await stream.read()
        XCTAssertEqual(readData1, data1)
        
        let readData2 = try await stream.read()
        XCTAssertEqual(readData2, data2)
    }
    
    func testOutOfOrderFrames() async throws {
        let data1 = "First".data(using: .utf8)!
        let data2 = "Second".data(using: .utf8)!
        
        // 先发送第二个帧
        let frame2 = StreamFrame(streamID: stream.id, offset: UInt64(data1.count), data: data2)
        try await stream.handleStreamFrame(frame2)
        
        // 此时不应该有可读数据
        let readData = stream.readWithoutBlocking()
        XCTAssertNil(readData)
        
        // 发送第一个帧
        let frame1 = StreamFrame(streamID: stream.id, offset: 0, data: data1)
        try await stream.handleStreamFrame(frame1)
        
        // 现在应该可以读取两个数据块
        let readData1 = try await stream.read()
        XCTAssertEqual(readData1, data1)
        
        let readData2 = try await stream.read()
        XCTAssertEqual(readData2, data2)
    }
    
    func testStreamClose() async throws {
        let testData = "Final data".data(using: .utf8)!
        
        // 写入数据然后关闭流
        try await stream.write(data: testData)
        try await stream.close()
        
        XCTAssertEqual(stream.state, .halfClosed)
        XCTAssertFalse(stream.canWrite())
        
        // 应该仍然能获取要发送的数据
        let frame = stream.getDataToSend(maxBytes: 1000)
        XCTAssertNotNil(frame)
        XCTAssertTrue(frame?.fin == false) // 数据帧
        
        // 标记数据已发送后，应该能获取FIN帧
        stream.markDataSent(bytes: testData.count)
        let finFrame = stream.getDataToSend(maxBytes: 1000)
        XCTAssertNotNil(finFrame)
        XCTAssertTrue(finFrame?.fin == true)
    }
    
    func testStreamReset() async throws {
        let errorCode: UInt64 = 42
        
        // 设置重置回调来验证
        var resetCalled = false
        var receivedErrorCode: UInt64 = 0
        
        stream.notifyConnectionForReset = { code in
            resetCalled = true
            receivedErrorCode = code
        }
        
        try await stream.reset(errorCode: errorCode)
        
        XCTAssertEqual(stream.state, .resetSent)
        XCTAssertFalse(stream.isActive)
        XCTAssertTrue(stream.isClosed)
        XCTAssertTrue(resetCalled)
        XCTAssertEqual(receivedErrorCode, errorCode)
    }
    
    func testHandleReset() {
        let errorCode: UInt64 = 123
        let finalSize: UInt64 = 456
        
        stream.handleReset(errorCode: errorCode, finalSize: finalSize)
        
        XCTAssertEqual(stream.state, .resetReceived)
        XCTAssertTrue(stream.isClosed)
        XCTAssertFalse(stream.canWrite())
        XCTAssertFalse(stream.canRead())
    }
    
    func testFlowControl() async throws {
        // 创建一个小窗口的流进行测试
        let smallStream = QUICStream(id: 4, type: .bidirectional, initialWindowSize: 10)
        
        let smallData = Data([1, 2, 3, 4, 5])
        let largeData = Data(repeating: 0xFF, count: 20)
        
        // 小数据应该可以写入
        try await smallStream.write(data: smallData)
        
        // 大数据应该触发流量控制阻塞
        do {
            try await smallStream.write(data: largeData)
            XCTFail("Should have thrown flow control blocked error")
        } catch StreamError.flowControlBlocked {
            // 预期的错误
        }
    }
    
    func testStreamWindowUpdate() async throws {
        let testData = "Test".data(using: .utf8)!
        
        // 写入数据消耗窗口
        try await stream.write(data: testData)
        
        let (sendWindow, _) = stream.getFlowControlInfo()
        XCTAssertEqual(sendWindow, 65536 - UInt64(testData.count))
        
        // 更新发送窗口
        stream.updateSendWindow(increment: 1000)
        
        let (newSendWindow, _) = stream.getFlowControlInfo()
        XCTAssertEqual(newSendWindow, 65536 - UInt64(testData.count) + 1000)
    }
    
    func testStreamFINHandling() async throws {
        let testData = "Final message".data(using: .utf8)!
        
        // 接收带FIN标志的帧
        let finFrame = StreamFrame(streamID: stream.id, offset: 0, data: testData, fin: true)
        try await stream.handleStreamFrame(finFrame)
        
        XCTAssertEqual(stream.state, .halfClosed)
        
        // 仍然可以读取数据
        let readData = try await stream.read()
        XCTAssertEqual(readData, testData)
    }
    
    func testDebugInfo() {
        let debugInfo = stream.debugInfo
        
        XCTAssertEqual(debugInfo.id, stream.id)
        XCTAssertEqual(debugInfo.state, stream.state)
        XCTAssertEqual(debugInfo.sendBufferSize, 0)
        XCTAssertEqual(debugInfo.receiveBufferSize, 0)
        XCTAssertEqual(debugInfo.bytesReceived, 0)
        XCTAssertEqual(debugInfo.bytesSent, 0)
    }
    
    func testCallbacks() async throws {
        var stateChangeCallbackCalled = false
        var errorCallbackCalled = false
        var dataAvailableCallbackCalled = false
        
        stream.onStateChange = { oldState, newState in
            stateChangeCallbackCalled = true
        }
        
        stream.onError = { error in
            errorCallbackCalled = true
        }
        
        stream.onDataAvailable = {
            dataAvailableCallbackCalled = true
        }
        
        // 触发状态变化
        try await stream.close()
        XCTAssertTrue(stateChangeCallbackCalled)
        
        // 触发数据可用回调
        let frame = StreamFrame(streamID: stream.id, offset: 0, data: Data([1, 2, 3]))
        try await stream.handleStreamFrame(frame)
        XCTAssertTrue(dataAvailableCallbackCalled)
    }
}