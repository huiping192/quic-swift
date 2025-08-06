import XCTest
@testable import QUICSwift

final class StreamManagerTests: XCTestCase {
    var streamManager: StreamManager!
    
    override func setUp() {
        super.setUp()
        streamManager = StreamManager(
            role: .client,
            maxBidirectionalStreams: 100,
            maxUnidirectionalStreams: 100,
            initialStreamWindowSize: 65536
        )
    }
    
    override func tearDown() {
        streamManager = nil
        super.tearDown()
    }
    
    func testStreamCreation() throws {
        // 创建客户端发起的双向流
        let bidiStream = try streamManager.createStream(type: .bidirectional, initiator: .client)
        XCTAssertEqual(bidiStream.id, 0) // 第一个客户端双向流ID应该是0
        XCTAssertEqual(bidiStream.type, .bidirectional)
        XCTAssertEqual(bidiStream.initiator, .client)
        
        // 创建客户端发起的单向流
        let uniStream = try streamManager.createStream(type: .unidirectional, initiator: .client)
        XCTAssertEqual(uniStream.id, 2) // 第一个客户端单向流ID应该是2
        XCTAssertEqual(uniStream.type, .unidirectional)
        XCTAssertEqual(uniStream.initiator, .client)
        
        // 创建第二个双向流
        let bidiStream2 = try streamManager.createStream(type: .bidirectional, initiator: .client)
        XCTAssertEqual(bidiStream2.id, 4) // 第二个客户端双向流ID应该是4
    }
    
    func testServerStreamCreation() throws {
        // 创建服务端发起的双向流
        let serverBidiStream = try streamManager.createStream(type: .bidirectional, initiator: .server)
        XCTAssertEqual(serverBidiStream.id, 1) // 第一个服务端双向流ID应该是1
        XCTAssertEqual(serverBidiStream.initiator, .server)
        
        // 创建服务端发起的单向流
        let serverUniStream = try streamManager.createStream(type: .unidirectional, initiator: .server)
        XCTAssertEqual(serverUniStream.id, 3) // 第一个服务端单向流ID应该是3
        XCTAssertEqual(serverUniStream.initiator, .server)
    }
    
    func testStreamIDGeneration() throws {
        var streamIDs: [UInt64] = []
        
        // 创建多个不同类型的流并记录ID
        for _ in 0..<3 {
            let clientBidi = try streamManager.createStream(type: .bidirectional, initiator: .client)
            let serverBidi = try streamManager.createStream(type: .bidirectional, initiator: .server)
            let clientUni = try streamManager.createStream(type: .unidirectional, initiator: .client)
            let serverUni = try streamManager.createStream(type: .unidirectional, initiator: .server)
            
            streamIDs.append(contentsOf: [clientBidi.id, serverBidi.id, clientUni.id, serverUni.id])
        }
        
        // 验证客户端双向流ID: 0, 4, 8
        XCTAssertEqual(streamIDs[0], 0)
        XCTAssertEqual(streamIDs[4], 4)
        XCTAssertEqual(streamIDs[8], 8)
        
        // 验证服务端双向流ID: 1, 5, 9
        XCTAssertEqual(streamIDs[1], 1)
        XCTAssertEqual(streamIDs[5], 5)
        XCTAssertEqual(streamIDs[9], 9)
        
        // 验证客户端单向流ID: 2, 6, 10
        XCTAssertEqual(streamIDs[2], 2)
        XCTAssertEqual(streamIDs[6], 6)
        XCTAssertEqual(streamIDs[10], 10)
        
        // 验证服务端单向流ID: 3, 7, 11
        XCTAssertEqual(streamIDs[3], 3)
        XCTAssertEqual(streamIDs[7], 7)
        XCTAssertEqual(streamIDs[11], 11)
    }
    
    func testStreamRetrieval() throws {
        let stream = try streamManager.createStream(type: .bidirectional, initiator: .client)
        let streamID = stream.id
        
        // 通过ID检索流
        let retrievedStream = streamManager.getStream(id: streamID)
        XCTAssertNotNil(retrievedStream)
        XCTAssertEqual(retrievedStream?.id, streamID)
        
        // 检索不存在的流
        let nonExistentStream = streamManager.getStream(id: 999)
        XCTAssertNil(nonExistentStream)
    }
    
    func testStreamFrameRouting() throws {
        // 创建一个流
        let stream = try streamManager.createStream(type: .bidirectional, initiator: .client)
        let streamID = stream.id
        
        // 创建流帧
        let testData = "Test data".data(using: .utf8)!
        let frame = StreamFrame(streamID: streamID, offset: 0, data: testData)
        
        // 路由帧到流
        let routedStream = streamManager.routeStreamFrame(frame)
        XCTAssertNotNil(routedStream)
        XCTAssertEqual(routedStream?.id, streamID)
    }
    
    func testPeerInitiatedStreamCreation() {
        // 模拟接收对端发起的流的帧
        let peerStreamID: UInt64 = 1 // 服务端发起的双向流
        let testData = "Peer data".data(using: .utf8)!
        let frame = StreamFrame(streamID: peerStreamID, offset: 0, data: testData)
        
        // 路由帧应该自动创建新流
        let peerStream = streamManager.routeStreamFrame(frame)
        XCTAssertNotNil(peerStream)
        XCTAssertEqual(peerStream?.id, peerStreamID)
        XCTAssertEqual(peerStream?.initiator, .server)
        
        // 验证流已被存储
        let retrievedStream = streamManager.getStream(id: peerStreamID)
        XCTAssertNotNil(retrievedStream)
    }
    
    func testStreamLimits() throws {
        // 设置较小的流限制进行测试
        let limitedManager = StreamManager(
            role: .client,
            maxBidirectionalStreams: 2,
            maxUnidirectionalStreams: 2
        )
        
        // 创建允许的最大数量的流
        _ = try limitedManager.createStream(type: .bidirectional, initiator: .client)
        _ = try limitedManager.createStream(type: .bidirectional, initiator: .client)
        
        // 尝试创建超出限制的流应该失败
        XCTAssertThrowsError(try limitedManager.createStream(type: .bidirectional, initiator: .client))
    }
    
    func testCanCreateStream() throws {
        // 初始状态应该可以创建流
        XCTAssertTrue(streamManager.canCreateStream(type: .bidirectional, initiator: .client))
        XCTAssertTrue(streamManager.canCreateStream(type: .unidirectional, initiator: .client))
        
        // 创建一些流后仍然应该可以创建（限制是100）
        for _ in 0..<10 {
            _ = try streamManager.createStream(type: .bidirectional, initiator: .client)
        }
        
        XCTAssertTrue(streamManager.canCreateStream(type: .bidirectional, initiator: .client))
    }
    
    func testStreamClosureAndRemoval() throws {
        let stream = try streamManager.createStream(type: .bidirectional, initiator: .client)
        let streamID = stream.id
        
        // 验证流存在
        XCTAssertNotNil(streamManager.getStream(id: streamID))
        
        // 关闭流
        streamManager.closeStream(id: streamID)
        
        // 流应该仍然存在但处于关闭状态
        let closedStream = streamManager.getStream(id: streamID)
        XCTAssertNotNil(closedStream)
        
        // 手动移除流
        streamManager.removeStream(id: streamID)
        
        // 现在流应该不存在了
        XCTAssertNil(streamManager.getStream(id: streamID))
    }
    
    func testStreamReset() throws {
        let stream = try streamManager.createStream(type: .bidirectional, initiator: .client)
        let streamID = stream.id
        let errorCode: UInt64 = 42
        
        // 重置流
        streamManager.resetStream(id: streamID, errorCode: errorCode)
        
        // 流状态应该会变化（异步操作，这里主要测试不会崩溃）
        XCTAssertNotNil(streamManager.getStream(id: streamID))
    }
    
    func testGetStreamsByType() throws {
        // 创建不同类型的流
        _ = try streamManager.createStream(type: .bidirectional, initiator: .client)
        _ = try streamManager.createStream(type: .bidirectional, initiator: .client)
        _ = try streamManager.createStream(type: .unidirectional, initiator: .client)
        
        let bidiStreams = streamManager.getStreams(type: .bidirectional)
        let uniStreams = streamManager.getStreams(type: .unidirectional)
        
        XCTAssertEqual(bidiStreams.count, 2)
        XCTAssertEqual(uniStreams.count, 1)
    }
    
    func testGetStreamsByInitiator() throws {
        // 创建不同发起者的流
        _ = try streamManager.createStream(type: .bidirectional, initiator: .client)
        _ = try streamManager.createStream(type: .bidirectional, initiator: .server)
        _ = try streamManager.createStream(type: .unidirectional, initiator: .client)
        
        let clientStreams = streamManager.getStreams(initiator: .client)
        let serverStreams = streamManager.getStreams(initiator: .server)
        
        XCTAssertEqual(clientStreams.count, 2)
        XCTAssertEqual(serverStreams.count, 1)
    }
    
    func testGetAllActiveStreams() throws {
        // 创建一些流
        let stream1 = try streamManager.createStream(type: .bidirectional, initiator: .client)
        let stream2 = try streamManager.createStream(type: .unidirectional, initiator: .client)
        
        let activeStreams = streamManager.getAllActiveStreams()
        XCTAssertEqual(activeStreams.count, 2)
        
        let streamIDs = Set(activeStreams.map { $0.id })
        XCTAssertTrue(streamIDs.contains(stream1.id))
        XCTAssertTrue(streamIDs.contains(stream2.id))
    }
    
    func testStreamLimitUpdates() throws {
        // 更新流限制
        streamManager.updateMaxStreams(bidirectional: 200, unidirectional: 150)
        
        let limits = streamManager.getStreamLimits()
        XCTAssertEqual(limits.bidirectional, 200)
        XCTAssertEqual(limits.unidirectional, 150)
    }
    
    func testDataToSend() throws {
        // 创建几个有数据要发送的流
        let stream1 = try streamManager.createStream(type: .bidirectional, initiator: .client)
        let stream2 = try streamManager.createStream(type: .bidirectional, initiator: .client)
        
        // 向流中写入数据
        let data1 = "Stream 1 data".data(using: .utf8)!
        let data2 = "Stream 2 data".data(using: .utf8)!
        
        try stream1.writeWithoutBlocking(data: data1)
        try stream2.writeWithoutBlocking(data: data2)
        
        // 获取要发送的数据
        let frames = streamManager.getDataToSend(maxTotalBytes: 1000)
        
        XCTAssertGreaterThan(frames.count, 0)
        XCTAssertLessThanOrEqual(frames.count, 2)
        
        // 验证帧包含正确的数据
        let streamIDs = Set(frames.map { $0.streamID })
        XCTAssertTrue(streamIDs.contains(stream1.id) || streamIDs.contains(stream2.id))
    }
    
    func testStatistics() throws {
        // 创建一些流
        _ = try streamManager.createStream(type: .bidirectional, initiator: .client)
        _ = try streamManager.createStream(type: .unidirectional, initiator: .client)
        
        let stats = streamManager.getStatistics()
        
        XCTAssertEqual(stats.activeStreams, 2)
        XCTAssertEqual(stats.totalStreamsCreated, 2)
        XCTAssertEqual(stats.totalBytesSent, 0)
        XCTAssertEqual(stats.totalBytesReceived, 0)
        XCTAssertGreaterThan(stats.averageStreamLifetime, 0)
    }
    
    func testDebugInfo() throws {
        _ = try streamManager.createStream(type: .bidirectional, initiator: .client)
        _ = try streamManager.createStream(type: .unidirectional, initiator: .server)
        
        let debugInfo = streamManager.debugInfo()
        
        XCTAssertTrue(debugInfo.contains("StreamManager Info"))
        XCTAssertTrue(debugInfo.contains("client"))
        XCTAssertTrue(debugInfo.contains("Active Streams: 2"))
        XCTAssertTrue(debugInfo.contains("Total Created: 2"))
    }
    
    func testPerformMaintenance() throws {
        // 创建一个流然后模拟其关闭
        let stream = try streamManager.createStream(type: .bidirectional, initiator: .client)
        
        // 这里我们无法直接测试维护逻辑，因为需要异步流状态变化
        // 但可以确保维护方法不会崩溃
        streamManager.performMaintenance()
        
        // 流应该仍然存在（因为还没有真正关闭）
        XCTAssertNotNil(streamManager.getStream(id: stream.id))
    }
    
    func testCallbacks() throws {
        var streamCreatedCalled = false
        var streamClosedCalled = false
        var streamLimitReachedCalled = false
        
        streamManager.onStreamCreated = { stream in
            streamCreatedCalled = true
        }
        
        streamManager.onStreamClosed = { streamID, state in
            streamClosedCalled = true
        }
        
        streamManager.onStreamLimitReached = { type in
            streamLimitReachedCalled = true
        }
        
        // 触发流创建回调
        _ = try streamManager.createStream(type: .bidirectional, initiator: .client)
        XCTAssertTrue(streamCreatedCalled)
        
        // 创建大量流来触发限制回调
        let limitedManager = StreamManager(role: .client, maxBidirectionalStreams: 1)
        limitedManager.onStreamLimitReached = { type in
            streamLimitReachedCalled = true
        }
        
        _ = try limitedManager.createStream(type: .bidirectional, initiator: .client)
        XCTAssertThrowsError(try limitedManager.createStream(type: .bidirectional, initiator: .client))
    }
}