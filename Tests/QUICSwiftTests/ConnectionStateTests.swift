import XCTest
@testable import QUICSwift

final class ConnectionStateTests: XCTestCase {
    
    func testInitialState() {
        let stateMachine = ConnectionStateMachine()
        XCTAssertEqual(stateMachine.state, .idle)
    }
    
    func testValidTransitions() {
        let stateMachine = ConnectionStateMachine()
        
        // idle -> connecting
        XCTAssertTrue(stateMachine.transition(event: .startConnecting))
        XCTAssertEqual(stateMachine.state, .connecting)
        
        // connecting -> connected
        XCTAssertTrue(stateMachine.transition(event: .connectionEstablished))
        XCTAssertEqual(stateMachine.state, .connected)
        
        // connected -> closing
        XCTAssertTrue(stateMachine.transition(event: .startClosing))
        XCTAssertEqual(stateMachine.state, .closing)
        
        // closing -> closed
        XCTAssertTrue(stateMachine.transition(event: .connectionClosed))
        XCTAssertEqual(stateMachine.state, .closed)
    }
    
    func testConnectionFailure() {
        let stateMachine = ConnectionStateMachine()
        let error = NetworkError.connectionClosed
        
        XCTAssertTrue(stateMachine.transition(event: .startConnecting))
        XCTAssertEqual(stateMachine.state, .connecting)
        
        XCTAssertTrue(stateMachine.transition(event: .connectionFailed(error)))
        XCTAssertEqual(stateMachine.state, .failed(error))
    }
    
    func testResetFromAnyState() {
        let stateMachine = ConnectionStateMachine()
        
        // Test reset from connecting
        XCTAssertTrue(stateMachine.transition(event: .startConnecting))
        XCTAssertTrue(stateMachine.transition(event: .reset))
        XCTAssertEqual(stateMachine.state, .closed)
        
        // Create new state machine and test reset from connected
        let stateMachine2 = ConnectionStateMachine()
        XCTAssertTrue(stateMachine2.transition(event: .startConnecting))
        XCTAssertTrue(stateMachine2.transition(event: .connectionEstablished))
        XCTAssertTrue(stateMachine2.transition(event: .reset))
        XCTAssertEqual(stateMachine2.state, .closed)
    }
    
    func testInvalidTransitions() {
        let stateMachine = ConnectionStateMachine()
        
        // Can't establish connection from idle
        XCTAssertFalse(stateMachine.transition(event: .connectionEstablished))
        XCTAssertEqual(stateMachine.state, .idle)
        
        // Can't close from idle
        XCTAssertFalse(stateMachine.transition(event: .startClosing))
        XCTAssertEqual(stateMachine.state, .idle)
    }
    
    func testStateChangeNotification() {
        let stateMachine = ConnectionStateMachine()
        var stateChanges: [(ConnectionState, ConnectionState)] = []
        
        stateMachine.onStateChange = { oldState, newState in
            stateChanges.append((oldState, newState))
        }
        
        XCTAssertTrue(stateMachine.transition(event: .startConnecting))
        XCTAssertTrue(stateMachine.transition(event: .connectionEstablished))
        
        XCTAssertEqual(stateChanges.count, 2)
        XCTAssertEqual(stateChanges[0].0, .idle)
        XCTAssertEqual(stateChanges[0].1, .connecting)
        XCTAssertEqual(stateChanges[1].0, .connecting)
        XCTAssertEqual(stateChanges[1].1, .connected)
    }
    
    func testStateProperties() {
        let stateMachine = ConnectionStateMachine()
        
        // Test idle state
        XCTAssertFalse(stateMachine.state.isConnected)
        XCTAssertFalse(stateMachine.state.canSend)
        XCTAssertFalse(stateMachine.state.canReceive)
        
        // Test connecting state
        XCTAssertTrue(stateMachine.transition(event: .startConnecting))
        XCTAssertFalse(stateMachine.state.isConnected)
        XCTAssertFalse(stateMachine.state.canSend)
        XCTAssertFalse(stateMachine.state.canReceive)
        
        // Test connected state
        XCTAssertTrue(stateMachine.transition(event: .connectionEstablished))
        XCTAssertTrue(stateMachine.state.isConnected)
        XCTAssertTrue(stateMachine.state.canSend)
        XCTAssertTrue(stateMachine.state.canReceive)
        
        // Test closing state
        XCTAssertTrue(stateMachine.transition(event: .startClosing))
        XCTAssertFalse(stateMachine.state.isConnected)
        XCTAssertFalse(stateMachine.state.canSend)
        XCTAssertTrue(stateMachine.state.canReceive)
        
        // Test closed state
        XCTAssertTrue(stateMachine.transition(event: .connectionClosed))
        XCTAssertFalse(stateMachine.state.isConnected)
        XCTAssertFalse(stateMachine.state.canSend)
        XCTAssertFalse(stateMachine.state.canReceive)
    }
    
    func testConcurrentAccess() async {
        let stateMachine = ConnectionStateMachine()
        let iterations = 100
        
        await withTaskGroup(of: Void.self) { group in
            // Task 1: Try to start connecting
            group.addTask {
                for _ in 0..<iterations {
                    _ = stateMachine.transition(event: .startConnecting)
                    try? await Task.sleep(nanoseconds: 1000)
                }
            }
            
            // Task 2: Try to establish connection
            group.addTask {
                for _ in 0..<iterations {
                    _ = stateMachine.transition(event: .connectionEstablished)
                    try? await Task.sleep(nanoseconds: 1000)
                }
            }
            
            // Task 3: Read state
            group.addTask {
                for _ in 0..<iterations {
                    _ = stateMachine.state
                    try? await Task.sleep(nanoseconds: 1000)
                }
            }
        }
        
        // Should not crash due to concurrent access
        XCTAssertTrue(true)
    }
}