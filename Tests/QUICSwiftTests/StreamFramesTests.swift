import XCTest
@testable import QUICSwift

final class StreamFramesTests: XCTestCase {
    
    func testStreamFrameCreation() {
        let testData = "Hello, QUIC Stream!".data(using: .utf8)!
        let frame = StreamFrame(
            streamID: 42,
            offset: 100,
            data: testData,
            fin: true,
            length: UInt64(testData.count)
        )
        
        XCTAssertEqual(frame.streamID, 42)
        XCTAssertEqual(frame.offset, 100)
        XCTAssertEqual(frame.data, testData)
        XCTAssertTrue(frame.fin)
        XCTAssertEqual(frame.length, UInt64(testData.count))
    }
    
    func testStreamFrameSerialization() {
        let testData = Data([1, 2, 3, 4, 5])
        let frame = StreamFrame(
            streamID: 10,
            offset: 0,
            data: testData,
            fin: false
        )
        
        let serialized = frame.serialize()
        XCTAssertFalse(serialized.isEmpty)
        
        // 验证帧类型字节
        let firstByte = serialized[0]
        let frameType = firstByte & 0xF8
        XCTAssertEqual(frameType, StreamFrameType.stream.rawValue)
    }
    
    func testStreamFrameParsing() throws {
        let testData = Data([1, 2, 3, 4, 5])
        let originalFrame = StreamFrame(
            streamID: 15,
            offset: 50,
            data: testData,
            fin: true
        )
        
        let serialized = originalFrame.serialize()
        let parsedFrame = try StreamFrame.parse(from: serialized)
        
        XCTAssertEqual(parsedFrame.streamID, originalFrame.streamID)
        XCTAssertEqual(parsedFrame.offset, originalFrame.offset)
        XCTAssertEqual(parsedFrame.data, originalFrame.data)
        XCTAssertEqual(parsedFrame.fin, originalFrame.fin)
    }
    
    func testStreamFrameWithoutOffset() throws {
        let testData = Data([10, 20, 30])
        let frame = StreamFrame(
            streamID: 8,
            offset: 0, // 零偏移量
            data: testData,
            fin: false
        )
        
        let serialized = frame.serialize()
        let parsedFrame = try StreamFrame.parse(from: serialized)
        
        XCTAssertEqual(parsedFrame.offset, 0)
        XCTAssertEqual(parsedFrame.data, testData)
    }
    
    func testStreamFrameWithoutLength() throws {
        let testData = Data([7, 8, 9])
        let frame = StreamFrame(
            streamID: 12,
            offset: 0,
            data: testData,
            fin: false,
            length: nil // 不包含长度字段
        )
        
        let serialized = frame.serialize()
        let parsedFrame = try StreamFrame.parse(from: serialized)
        
        XCTAssertEqual(parsedFrame.data, testData)
        XCTAssertNil(parsedFrame.length)
    }
    
    func testResetStreamFrame() throws {
        let frame = ResetStreamFrame(
            streamID: 123,
            errorCode: 456,
            finalSize: 789
        )
        
        let serialized = frame.serialize()
        let parsedFrame = try ResetStreamFrame.parse(from: serialized)
        
        XCTAssertEqual(parsedFrame.streamID, frame.streamID)
        XCTAssertEqual(parsedFrame.errorCode, frame.errorCode)
        XCTAssertEqual(parsedFrame.finalSize, frame.finalSize)
    }
    
    func testStopSendingFrame() throws {
        let frame = StopSendingFrame(
            streamID: 555,
            errorCode: 777
        )
        
        let serialized = frame.serialize()
        let parsedFrame = try StopSendingFrame.parse(from: serialized)
        
        XCTAssertEqual(parsedFrame.streamID, frame.streamID)
        XCTAssertEqual(parsedFrame.errorCode, frame.errorCode)
    }
    
    func testMaxStreamDataFrame() throws {
        let frame = MaxStreamDataFrame(
            streamID: 99,
            maxStreamData: 65536
        )
        
        let serialized = frame.serialize()
        let parsedFrame = try MaxStreamDataFrame.parse(from: serialized)
        
        XCTAssertEqual(parsedFrame.streamID, frame.streamID)
        XCTAssertEqual(parsedFrame.maxStreamData, frame.maxStreamData)
    }
    
    func testStreamDataBlockedFrame() throws {
        let frame = StreamDataBlockedFrame(
            streamID: 200,
            streamDataLimit: 32768
        )
        
        let serialized = frame.serialize()
        let parsedFrame = try StreamDataBlockedFrame.parse(from: serialized)
        
        XCTAssertEqual(parsedFrame.streamID, frame.streamID)
        XCTAssertEqual(parsedFrame.streamDataLimit, frame.streamDataLimit)
    }
    
    func testMaxStreamsFrameBidirectional() throws {
        let frame = MaxStreamsFrame(
            maxStreams: 1000,
            bidirectional: true
        )
        
        let serialized = frame.serialize()
        let parsedFrame = try MaxStreamsFrame.parse(from: serialized)
        
        XCTAssertEqual(parsedFrame.maxStreams, frame.maxStreams)
        XCTAssertTrue(parsedFrame.bidirectional)
    }
    
    func testMaxStreamsFrameUnidirectional() throws {
        let frame = MaxStreamsFrame(
            maxStreams: 500,
            bidirectional: false
        )
        
        let serialized = frame.serialize()
        let parsedFrame = try MaxStreamsFrame.parse(from: serialized)
        
        XCTAssertEqual(parsedFrame.maxStreams, frame.maxStreams)
        XCTAssertFalse(parsedFrame.bidirectional)
    }
    
    func testStreamsBlockedFrame() throws {
        let frame = StreamsBlockedFrame(
            streamLimit: 250,
            bidirectional: true
        )
        
        let serialized = frame.serialize()
        let parsedFrame = try StreamsBlockedFrame.parse(from: serialized)
        
        XCTAssertEqual(parsedFrame.streamLimit, frame.streamLimit)
        XCTAssertTrue(parsedFrame.bidirectional)
    }
    
    func testStreamFrameParserGeneric() throws {
        // 测试STREAM帧解析
        let streamFrame = StreamFrame(streamID: 42, offset: 0, data: Data([1, 2, 3]))
        let streamSerialized = streamFrame.serialize()
        let streamParsed = try StreamFrameParser.parseFrame(from: streamSerialized)
        XCTAssertTrue(streamParsed is StreamFrame)
        
        // 测试RESET_STREAM帧解析
        let resetFrame = ResetStreamFrame(streamID: 42, errorCode: 123, finalSize: 456)
        let resetSerialized = resetFrame.serialize()
        let resetParsed = try StreamFrameParser.parseFrame(from: resetSerialized)
        XCTAssertTrue(resetParsed is ResetStreamFrame)
        
        // 测试MAX_STREAM_DATA帧解析
        let maxDataFrame = MaxStreamDataFrame(streamID: 42, maxStreamData: 65536)
        let maxDataSerialized = maxDataFrame.serialize()
        let maxDataParsed = try StreamFrameParser.parseFrame(from: maxDataSerialized)
        XCTAssertTrue(maxDataParsed is MaxStreamDataFrame)
    }
    
    func testStreamFrameFlags() {
        let testData = Data([1, 2, 3])
        
        // 测试FIN标志
        let finFrame = StreamFrame(streamID: 1, offset: 0, data: testData, fin: true)
        let finSerialized = finFrame.serialize()
        let firstByte = finSerialized[0]
        XCTAssertTrue((firstByte & 0x01) != 0) // FIN标志应该被设置
        
        // 测试偏移量标志
        let offsetFrame = StreamFrame(streamID: 1, offset: 100, data: testData)
        let offsetSerialized = offsetFrame.serialize()
        let offsetFirstByte = offsetSerialized[0]
        XCTAssertTrue((offsetFirstByte & 0x04) != 0) // OFF标志应该被设置
        
        // 测试长度标志
        let lengthFrame = StreamFrame(streamID: 1, offset: 0, data: testData, length: 10)
        let lengthSerialized = lengthFrame.serialize()
        let lengthFirstByte = lengthSerialized[0]
        XCTAssertTrue((lengthFirstByte & 0x02) != 0) // LEN标志应该被设置
    }
    
    func testStreamFrameTypeDetection() {
        XCTAssertTrue(StreamFrameParser.isStreamFrame(0x08))
        XCTAssertTrue(StreamFrameParser.isStreamFrame(0x0F)) // 带所有标志的STREAM帧
        XCTAssertFalse(StreamFrameParser.isStreamFrame(0x04)) // RESET_STREAM
        
        XCTAssertTrue(StreamFrameParser.isStreamControlFrame(0x04)) // RESET_STREAM
        XCTAssertTrue(StreamFrameParser.isStreamControlFrame(0x05)) // STOP_SENDING
        XCTAssertTrue(StreamFrameParser.isStreamControlFrame(0x11)) // MAX_STREAM_DATA
        XCTAssertFalse(StreamFrameParser.isStreamControlFrame(0x08)) // STREAM帧
    }
    
    func testInvalidFrameParsing() {
        // 空数据
        XCTAssertThrowsError(try StreamFrame.parse(from: Data()))
        
        // 错误的帧类型
        let invalidData = Data([0x01, 0x42]) // 不是STREAM帧类型
        XCTAssertThrowsError(try StreamFrame.parse(from: invalidData))
    }
    
    func testLargeStreamFrame() throws {
        let largeData = Data(repeating: 0xAB, count: 10000)
        let frame = StreamFrame(
            streamID: 1000000,
            offset: 500000,
            data: largeData,
            fin: false
        )
        
        let serialized = frame.serialize()
        let parsedFrame = try StreamFrame.parse(from: serialized)
        
        XCTAssertEqual(parsedFrame.streamID, frame.streamID)
        XCTAssertEqual(parsedFrame.offset, frame.offset)
        XCTAssertEqual(parsedFrame.data.count, largeData.count)
        XCTAssertEqual(parsedFrame.data, largeData)
    }
    
    func testDebugDescriptions() {
        let streamFrame = StreamFrame(streamID: 42, offset: 100, data: Data([1, 2, 3]), fin: true)
        let debugDescription = streamFrame.debugDescription
        XCTAssertTrue(debugDescription.contains("STREAM"))
        XCTAssertTrue(debugDescription.contains("42"))
        XCTAssertTrue(debugDescription.contains("100"))
        XCTAssertTrue(debugDescription.contains("fin=true"))
        
        let resetFrame = ResetStreamFrame(streamID: 123, errorCode: 456, finalSize: 789)
        let resetDescription = resetFrame.debugDescription
        XCTAssertTrue(resetDescription.contains("RESET_STREAM"))
        XCTAssertTrue(resetDescription.contains("123"))
        XCTAssertTrue(resetDescription.contains("456"))
        XCTAssertTrue(resetDescription.contains("789"))
    }
    
    func testRoundTripSerialization() throws {
        let frames: [Any] = [
            StreamFrame(streamID: 42, offset: 0, data: Data([1, 2, 3]), fin: true),
            ResetStreamFrame(streamID: 42, errorCode: 123, finalSize: 456),
            StopSendingFrame(streamID: 42, errorCode: 789),
            MaxStreamDataFrame(streamID: 42, maxStreamData: 65536),
            StreamDataBlockedFrame(streamID: 42, streamDataLimit: 32768),
            MaxStreamsFrame(maxStreams: 1000, bidirectional: true),
            StreamsBlockedFrame(streamLimit: 500, bidirectional: false)
        ]
        
        for frame in frames {
            var serialized: Data
            
            switch frame {
            case let streamFrame as StreamFrame:
                serialized = streamFrame.serialize()
                let parsed = try StreamFrame.parse(from: serialized)
                XCTAssertEqual(parsed.streamID, streamFrame.streamID)
                XCTAssertEqual(parsed.data, streamFrame.data)
                
            case let resetFrame as ResetStreamFrame:
                serialized = resetFrame.serialize()
                let parsed = try ResetStreamFrame.parse(from: serialized)
                XCTAssertEqual(parsed.streamID, resetFrame.streamID)
                XCTAssertEqual(parsed.errorCode, resetFrame.errorCode)
                
            case let stopFrame as StopSendingFrame:
                serialized = stopFrame.serialize()
                let parsed = try StopSendingFrame.parse(from: serialized)
                XCTAssertEqual(parsed.streamID, stopFrame.streamID)
                XCTAssertEqual(parsed.errorCode, stopFrame.errorCode)
                
            case let maxDataFrame as MaxStreamDataFrame:
                serialized = maxDataFrame.serialize()
                let parsed = try MaxStreamDataFrame.parse(from: serialized)
                XCTAssertEqual(parsed.streamID, maxDataFrame.streamID)
                XCTAssertEqual(parsed.maxStreamData, maxDataFrame.maxStreamData)
                
            case let blockedFrame as StreamDataBlockedFrame:
                serialized = blockedFrame.serialize()
                let parsed = try StreamDataBlockedFrame.parse(from: serialized)
                XCTAssertEqual(parsed.streamID, blockedFrame.streamID)
                XCTAssertEqual(parsed.streamDataLimit, blockedFrame.streamDataLimit)
                
            case let maxStreamsFrame as MaxStreamsFrame:
                serialized = maxStreamsFrame.serialize()
                let parsed = try MaxStreamsFrame.parse(from: serialized)
                XCTAssertEqual(parsed.maxStreams, maxStreamsFrame.maxStreams)
                XCTAssertEqual(parsed.bidirectional, maxStreamsFrame.bidirectional)
                
            case let streamsBlockedFrame as StreamsBlockedFrame:
                serialized = streamsBlockedFrame.serialize()
                let parsed = try StreamsBlockedFrame.parse(from: serialized)
                XCTAssertEqual(parsed.streamLimit, streamsBlockedFrame.streamLimit)
                XCTAssertEqual(parsed.bidirectional, streamsBlockedFrame.bidirectional)
                
            default:
                XCTFail("Unexpected frame type")
            }
        }
    }
}