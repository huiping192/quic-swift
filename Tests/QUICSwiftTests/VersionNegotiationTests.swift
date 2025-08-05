import XCTest
@testable import QUICSwift

final class VersionNegotiationTests: XCTestCase {
    
    func testVersionSupport() {
        XCTAssertTrue(VersionNegotiation.isVersionSupported(QUICVersion.current))
        XCTAssertFalse(VersionNegotiation.isVersionSupported(0xDEADBEEF))
        XCTAssertFalse(VersionNegotiation.isVersionSupported(QUICVersion.negotiation))
    }
    
    func testVersionSelection() {
        let clientVersions: [UInt32] = [0xDEADBEEF, QUICVersion.current, 0xCAFEBABE]
        let selectedVersion = VersionNegotiation.selectVersion(from: clientVersions)
        
        XCTAssertEqual(selectedVersion, QUICVersion.current)
    }
    
    func testVersionSelectionNoMatch() {
        let clientVersions: [UInt32] = [0xDEADBEEF, 0xCAFEBABE]
        let selectedVersion = VersionNegotiation.selectVersion(from: clientVersions)
        
        XCTAssertNil(selectedVersion)
    }
    
    func testVersionNegotiationPacketCreation() {
        let destCID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let srcCID = ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        
        let packetData = VersionNegotiation.createVersionNegotiationPacket(
            destinationConnectionID: destCID,
            sourceConnectionID: srcCID
        )
        
        XCTAssertFalse(packetData.isEmpty)
        
        // 验证包头
        let firstByte = packetData[0]
        XCTAssertEqual(firstByte & 0x80, 0x80) // Header Form = 1
        XCTAssertEqual(firstByte & 0x40, 0x40) // Fixed Bit = 1
        
        // 验证版本字段为0
        let versionBytes = packetData.subdata(in: 1..<5)
        let version = versionBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        XCTAssertEqual(version, QUICVersion.negotiation)
    }
    
    func testVersionNegotiationPacketParsing() throws {
        let destCID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let srcCID = ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        
        let packetData = VersionNegotiation.createVersionNegotiationPacket(
            destinationConnectionID: destCID,
            sourceConnectionID: srcCID
        )
        
        let packet = try QUICPacket.parse(from: packetData)
        let versions = try VersionNegotiation.extractVersionsFromNegotiationPacket(packet)
        
        XCTAssertEqual(versions, QUICVersion.supportedVersions)
    }
    
    func testVersionNegotiationRequired() {
        XCTAssertTrue(VersionNegotiation.requiresVersionNegotiation(clientVersion: 0xDEADBEEF))
        XCTAssertFalse(VersionNegotiation.requiresVersionNegotiation(clientVersion: QUICVersion.current))
        XCTAssertFalse(VersionNegotiation.requiresVersionNegotiation(clientVersion: QUICVersion.negotiation))
    }
    
    func testVersionNegotiationStateMachine() {
        let stateMachine = VersionNegotiationStateMachine()
        
        // 测试初始状态
        if case .initial = stateMachine.state {
            // 正确的初始状态
        } else {
            XCTFail("Expected initial state")
        }
        
        // 创建版本协商包
        let destCID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let srcCID = ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let packetData = VersionNegotiation.createVersionNegotiationPacket(
            destinationConnectionID: destCID,
            sourceConnectionID: srcCID
        )
        
        do {
            let packet = try QUICPacket.parse(from: packetData)
            let result = stateMachine.handleVersionNegotiationAsClient(packet: packet)
            
            switch result {
            case .success(let selectedVersion):
                XCTAssertEqual(selectedVersion, QUICVersion.current)
                
                // 验证状态变化
                if case .versionSelected(let version) = stateMachine.state {
                    XCTAssertEqual(version, QUICVersion.current)
                } else {
                    XCTFail("Expected versionSelected state")
                }
                
            case .failure(let error):
                XCTFail("Version negotiation should succeed: \(error)")
            }
        } catch {
            XCTFail("Packet parsing failed: \(error)")
        }
    }
    
    func testVersionNegotiationStateMachineFailure() {
        let stateMachine = VersionNegotiationStateMachine()
        
        // 创建一个包含不支持版本的协商包
        var builder = PacketBuilder()
        builder.writeUInt8(0xC0) // 长包头
        builder.writeUInt32(QUICVersion.negotiation) // 版本协商
        builder.writeUInt8(0x44) // 连接ID长度
        builder.writeBytes(Data([0x01, 0x02, 0x03, 0x04])) // 目标CID
        builder.writeBytes(Data([0x05, 0x06, 0x07, 0x08])) // 源CID
        builder.writeUInt32(0xDEADBEEF) // 不支持的版本
        builder.writeUInt32(0xCAFEBABE) // 另一个不支持的版本
        
        let packetData = builder.build()
        
        do {
            let packet = try QUICPacket.parse(from: packetData)
            let result = stateMachine.handleVersionNegotiationAsClient(packet: packet)
            
            switch result {
            case .success:
                XCTFail("Version negotiation should fail with unsupported versions")
                
            case .failure:
                // 验证失败状态
                if case .failed = stateMachine.state {
                    // 正确的失败状态
                } else {
                    XCTFail("Expected failed state")
                }
            }
        } catch {
            XCTFail("Packet parsing failed: \(error)")
        }
    }
    
    func testServerVersionNegotiation() {
        let stateMachine = VersionNegotiationStateMachine()
        
        // 测试支持的版本
        let supportedResult = stateMachine.handleVersionNegotiationAsServer(clientVersion: QUICVersion.current)
        switch supportedResult {
        case .success(let (needsNegotiation, _)):
            XCTAssertFalse(needsNegotiation)
        case .failure(let error):
            XCTFail("Should succeed for supported version: \(error)")
        }
        
        // 重置状态机
        stateMachine.reset()
        
        // 测试不支持的版本
        let unsupportedResult = stateMachine.handleVersionNegotiationAsServer(clientVersion: 0xDEADBEEF)
        switch unsupportedResult {
        case .success(let (needsNegotiation, _)):
            XCTAssertTrue(needsNegotiation)
        case .failure(let error):
            XCTFail("Should succeed but indicate negotiation needed: \(error)")
        }
    }
    
    func testVersionNegotiationHelper() {
        let destCID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let srcCID = ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let payload = Data([0xAA, 0xBB, 0xCC])
        
        let retryPacketData = VersionNegotiationHelper.createRetryInitialPacket(
            selectedVersion: QUICVersion.current,
            destinationConnectionID: destCID,
            sourceConnectionID: srcCID,
            payload: payload
        )
        
        XCTAssertFalse(retryPacketData.isEmpty)
        
        // 验证生成的包可以被解析
        do {
            let packet = try QUICPacket.parse(from: retryPacketData)
            XCTAssertEqual(packet.headerForm, .long)
            XCTAssertEqual(packet.packetType, .initial)
            XCTAssertEqual(packet.version, QUICVersion.current)
            XCTAssertEqual(packet.destinationConnectionID, destCID)
            XCTAssertEqual(packet.sourceConnectionID, srcCID)
        } catch {
            XCTFail("Generated retry packet should be parseable: \(error)")
        }
    }
    
    func testVersionNegotiationPacketValidation() {
        let destCID = ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let srcCID = ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        
        let packetData = VersionNegotiation.createVersionNegotiationPacket(
            destinationConnectionID: destCID,
            sourceConnectionID: srcCID
        )
        
        do {
            let packet = try QUICPacket.parse(from: packetData)
            let validationResult = VersionNegotiationHelper.validateVersionNegotiationPacket(packet)
            
            switch validationResult {
            case .success:
                // 验证通过
                break
            case .failure(let error):
                XCTFail("Validation should succeed: \(error)")
            }
        } catch {
            XCTFail("Packet parsing failed: \(error)")
        }
    }
    
    func testNewConnectionIDGeneration() {
        let newCID = VersionNegotiationHelper.generateNewConnectionIDAfterNegotiation()
        
        XCTAssertGreaterThanOrEqual(newCID.length, 8)
        XCTAssertLessThanOrEqual(newCID.length, 20)
        XCTAssertFalse(newCID.isEmpty)
        
        // 生成多个ID应该不同
        let anotherCID = VersionNegotiationHelper.generateNewConnectionIDAfterNegotiation()
        XCTAssertNotEqual(newCID, anotherCID)
    }
}