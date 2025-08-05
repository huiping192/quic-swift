import XCTest
@testable import QUICSwift

final class ErrorTests: XCTestCase {
    
    func testNetworkErrorDescriptions() {
        let errors: [NetworkError] = [
            .notConnected,
            .connectionClosed,
            .invalidEndpoint,
            .sendTimeout,
            .receiveTimeout,
            .bindFailed("Test reason"),
            .listenerFailed("Test reason")
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
        
        // Test specific error descriptions
        XCTAssertEqual(NetworkError.notConnected.errorDescription, "Connection not established")
        XCTAssertEqual(NetworkError.bindFailed("port in use").errorDescription, "Failed to bind to address: port in use")
    }
    
    func testParsingErrorDescriptions() {
        let errors: [ParsingError] = [
            .insufficientData,
            .invalidVariableInt,
            .malformedPacket,
            .unsupportedVersion,
            .invalidOffset,
            .bufferOverflow
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
        
        // Test specific error descriptions
        XCTAssertEqual(ParsingError.insufficientData.errorDescription, "Insufficient data for parsing")
        XCTAssertEqual(ParsingError.invalidVariableInt.errorDescription, "Invalid variable integer encoding")
    }
    
    func testConnectionErrorDescriptions() {
        let errors: [ConnectionError] = [
            .invalidState,
            .handshakeFailed,
            .protocolViolation("Invalid frame type"),
            .timeout
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
        
        // Test specific error descriptions
        XCTAssertEqual(ConnectionError.invalidState.errorDescription, "Invalid connection state")
        XCTAssertEqual(ConnectionError.protocolViolation("test").errorDescription, "Protocol violation: test")
    }
    
    func testErrorEquality() {
        // Test basic error case equality
        XCTAssertTrue(NetworkError.notConnected == NetworkError.notConnected)
        XCTAssertFalse(NetworkError.notConnected == NetworkError.connectionClosed)
        
        // Test ParsingError equality
        XCTAssertTrue(ParsingError.insufficientData == ParsingError.insufficientData)
        XCTAssertFalse(ParsingError.insufficientData == ParsingError.invalidVariableInt)
        
        // Test ConnectionError equality (excluding associated values)
        XCTAssertTrue(ConnectionError.invalidState == ConnectionError.invalidState)
        XCTAssertFalse(ConnectionError.invalidState == ConnectionError.handshakeFailed)
    }
    
    func testErrorAsLocalizedError() {
        let networkError: LocalizedError = NetworkError.notConnected
        XCTAssertNotNil(networkError.errorDescription)
        
        let parsingError: LocalizedError = ParsingError.insufficientData
        XCTAssertNotNil(parsingError.errorDescription)
        
        let connectionError: LocalizedError = ConnectionError.invalidState
        XCTAssertNotNil(connectionError.errorDescription)
    }
    
    func testErrorInThrowingContext() {
        func throwNetworkError() throws {
            throw NetworkError.notConnected
        }
        
        func throwParsingError() throws {
            throw ParsingError.insufficientData
        }
        
        func throwConnectionError() throws {
            throw ConnectionError.invalidState
        }
        
        XCTAssertThrowsError(try throwNetworkError()) { error in
            XCTAssertTrue(error is NetworkError)
            if let networkError = error as? NetworkError {
                XCTAssertTrue(networkError == .notConnected)
            }
        }
        
        XCTAssertThrowsError(try throwParsingError()) { error in
            XCTAssertTrue(error is ParsingError)
            if let parsingError = error as? ParsingError {
                XCTAssertTrue(parsingError == .insufficientData)
            }
        }
        
        XCTAssertThrowsError(try throwConnectionError()) { error in
            XCTAssertTrue(error is ConnectionError)
            if let connectionError = error as? ConnectionError {
                XCTAssertTrue(connectionError == .invalidState)
            }
        }
    }
}