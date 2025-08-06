import XCTest
@testable import QUICSwift

final class StreamBufferTests: XCTestCase {
    var buffer: StreamBuffer!
    
    override func setUp() {
        super.setUp()
        buffer = StreamBuffer(maxBufferSize: 1024)
    }
    
    override func tearDown() {
        buffer = nil
        super.tearDown()
    }
    
    func testBasicDataAppend() {
        let data = Data([1, 2, 3, 4, 5])
        
        XCTAssertNoThrow(try buffer.append(data))
        XCTAssertEqual(buffer.currentSize, 5)
        XCTAssertFalse(buffer.isEmpty)
    }
    
    func testDataReading() {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        try! buffer.append(data1)
        try! buffer.append(data2)
        
        if let sentData = buffer.getDataToSend(maxBytes: 10) {
            XCTAssertEqual(sentData.data, data1)
            XCTAssertEqual(sentData.offset, 0)
        } else {
            XCTFail("Should have data to send")
        }
    }
    
    func testMarkSent() {
        let data = Data([1, 2, 3, 4, 5])
        try! buffer.append(data)
        
        buffer.markSent(bytes: 3)
        
        if let sentData = buffer.getDataToSend(maxBytes: 10) {
            XCTAssertEqual(sentData.data, Data([4, 5]))
            XCTAssertEqual(sentData.offset, 3)
        } else {
            XCTFail("Should have remaining data to send")
        }
    }
    
    func testReceiveDataInOrder() {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        try! buffer.addData(data1, at: 0)
        try! buffer.addData(data2, at: 3)
        
        XCTAssertTrue(buffer.hasData())
        
        let readData1 = buffer.read()
        XCTAssertEqual(readData1, data1)
        
        let readData2 = buffer.read()
        XCTAssertEqual(readData2, data2)
        
        XCTAssertFalse(buffer.hasData())
    }
    
    func testReceiveDataOutOfOrder() {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        // 先接收后面的数据
        try! buffer.addData(data2, at: 3)
        XCTAssertFalse(buffer.hasData()) // 应该没有可读数据
        
        // 再接收前面的数据
        try! buffer.addData(data1, at: 0)
        XCTAssertTrue(buffer.hasData()) // 现在应该有可读数据
        
        let readData1 = buffer.read()
        XCTAssertEqual(readData1, data1)
        
        let readData2 = buffer.read()
        XCTAssertEqual(readData2, data2)
    }
    
    func testOverlappingData() {
        let data1 = Data([1, 2, 3, 4])
        let data2 = Data([3, 4, 5, 6]) // 与data1重叠
        
        try! buffer.addData(data1, at: 0)
        try! buffer.addData(data2, at: 2) // 在偏移量2处添加重叠数据
        
        let readData = buffer.read()
        XCTAssertEqual(readData, Data([1, 2, 3, 4]))
        
        let readData2 = buffer.read()
        XCTAssertEqual(readData2, Data([5, 6])) // 只有非重叠部分
    }
    
    func testBufferOverflow() {
        let largeData = Data(repeating: 0xFF, count: 2000) // 超过1024字节限制
        
        XCTAssertThrowsError(try buffer.append(largeData)) { error in
            XCTAssertTrue(error is StreamError)
            if case StreamError.bufferOverflow = error {
                // 预期的错误
            } else {
                XCTFail("Expected buffer overflow error")
            }
        }
    }
    
    func testReadUpTo() {
        let data = Data([1, 2, 3, 4, 5, 6, 7, 8])
        try! buffer.addData(data, at: 0)
        
        let readData1 = buffer.readUpTo(3)
        XCTAssertEqual(readData1, Data([1, 2, 3]))
        
        let readData2 = buffer.readUpTo(10) // 超过剩余数据
        XCTAssertEqual(readData2, Data([4, 5, 6, 7, 8]))
        
        XCTAssertFalse(buffer.hasData())
    }
    
    func testGapDetection() {
        try! buffer.addData(Data([1, 2, 3]), at: 0)
        try! buffer.addData(Data([7, 8, 9]), at: 6) // 创建间隙
        
        let gaps = buffer.getGaps()
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0], 3..<6)
    }
    
    func testCompleteBuffer() {
        let data = Data([1, 2, 3, 4, 5])
        try! buffer.append(data)
        
        XCTAssertFalse(buffer.isCompleted)
        buffer.markComplete()
        XCTAssertTrue(buffer.isCompleted)
    }
    
    func testClearBuffer() {
        let data = Data([1, 2, 3, 4, 5])
        try! buffer.append(data)
        
        XCTAssertFalse(buffer.isEmpty)
        buffer.clear()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.currentSize, 0)
    }
    
    func testStatistics() {
        let sendData = Data([1, 2, 3])
        let receiveData = Data([4, 5, 6])
        
        try! buffer.append(sendData)
        try! buffer.addData(receiveData, at: 0)
        
        let stats = buffer.getStatistics()
        XCTAssertEqual(stats.totalSent, 3)
        XCTAssertEqual(stats.totalReceived, 3)
        XCTAssertEqual(stats.bufferSize, 6)
    }
    
    func testAvailableData() {
        try! buffer.addData(Data([1, 2, 3]), at: 0)
        try! buffer.addData(Data([4, 5, 6]), at: 3)
        try! buffer.addData(Data([10, 11]), at: 10) // 创建间隙
        
        XCTAssertEqual(buffer.availableData, 6) // 只有连续的数据可用
    }
}