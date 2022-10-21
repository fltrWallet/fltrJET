//===----------------------------------------------------------------------===//
//
// This source file is part of the fltrJET open source project
//
// Copyright (c) 2022 fltrWallet AG and the fltrJET project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
@testable import fltrJET
import MetalKit
import XCTest

final class FlrtJetTestableTests: XCTestCase {
    var device: MTLDevice!
    var jetDevice: JET.MTLDeviceStates!
    var hashKernel: JET.HashKernel!
    
    
    override func setUp() {
        self.device = MTLCreateSystemDefaultDevice()
        self.jetDevice = .init(device: self.device)
        
        let kernel = expectation(description: "kernel")
        JET.HashKernel.make(device: self.jetDevice) {
            switch $0 {
            case .success(let kernel):
                self.hashKernel = kernel
            case .failure(let error):
                XCTFail(error.localizedDescription)
            }
            kernel.fulfill()
        }
        wait(for: [kernel], timeout: 1.0)
    }
    
    override func tearDown() {
        self.jetDevice = nil
        self.device = nil
        self.hashKernel = nil
    }

    func testModuloExtend() {
        var testCollection: [String] = []
        
        (1...100).forEach { index in
            testCollection.append("test")
            XCTAssertEqual(testCollection.count, index)
            var copy = testCollection
            moduloExtend(&copy, modulo: 101, with: "extended")
            XCTAssertEqual(copy.count, 101)
            XCTAssertEqual(copy[index - 1], "test")
            XCTAssertEqual(copy[index], "extended")
        }
    }
    
    func testModuloExtendInteger() {
        var testCollection: [Int] = []
        
        (1...100).forEach { index in
            testCollection.append(.max)
            XCTAssertEqual(testCollection.count, index)
            var copy = testCollection
            moduloExtend(&copy, modulo: 100)
            XCTAssertEqual(copy.count, 100)
        }
    }
    
    func testExtendOpcodes() {
        let byteArray = [ UInt8(1), ]
        
        (1...100).forEach { index in
            let test: [UInt8] = byteArray.extend(to: 1000, opcodeCount: index)
            XCTAssertEqual(test.count, 1000)
            XCTAssertEqual(test.last!, UInt8(index))
        }
    }
    
    func testDoubleBuffer() {
        let dbl = try! JET.DoubleBuffer.makeBuffers(using: self.device)
        XCTAssertEqual(dbl.full(), false)
        XCTAssertEqual(dbl.idle(), true)
        
        let a1 = expectation(description: "a1")
        let a2 = expectation(description: "a2")
        let (commandBuffer, encoder) = self.hashKernel.newCommand()
        commandBuffer.addCompletedHandler { _ in
            Thread.sleep(forTimeInterval: 0.2)
            a1.fulfill()
        }
        encoder.endEncoding()
        dbl.enqueue(commandBuffer, callback: { result in
            switch result {
            case .failure(JET.Error.stop):
                XCTFail("unexpected stop callback")
            case .failure, .success:
                XCTFail("unexpected callback")
            }
        }) { _ in
            a2.fulfill()
        }
        XCTAssertEqual(dbl.full(), true)
        XCTAssertEqual(dbl.idle(), false)
        dbl.commit()
        XCTAssertEqual(dbl.full(), false)

        let b1 = expectation(description: "b1")
        let b2 = expectation(description: "b2")
        let (commandBuffer2, encoder2) = self.hashKernel.newCommand()
        commandBuffer2.addCompletedHandler { _ in
            Thread.sleep(forTimeInterval: 0.2)
            b1.fulfill()
        }
        encoder2.endEncoding()
        dbl.enqueue(commandBuffer2, callback: { result in
            switch result {
            case .failure(JET.Error.stop):
                XCTFail("unexpected stop callback")
            case .failure, .success:
                XCTFail("unexpected callback")
            }
        }) { _ in
            b2.fulfill()
        }
        XCTAssertEqual(dbl.full(), true)
        XCTAssertEqual(dbl.idle(), false)
        dbl.commit()
        wait(for: [ a1, a2, b1, b2, ], timeout: 2)
        
        XCTAssertEqual(dbl.full(), false)
        XCTAssertEqual(dbl.idle(), true)
    }
    
    func testDoubleBufferStop() {
        let dbl = try! JET.DoubleBuffer.makeBuffers(using: self.device)

        let a1 = expectation(description: "a1")
        let a2 = expectation(description: "a2")
        let a3 = expectation(description: "a3")
        let (commandBuffer, encoder) = self.hashKernel.newCommand()
        commandBuffer.addCompletedHandler { _ in
            Thread.sleep(forTimeInterval: 0.2)
            a1.fulfill()
        }
        encoder.endEncoding()
        dbl.enqueue(commandBuffer, callback: { result in
            switch result {
            case .failure(JET.Error.stop):
                a3.fulfill()
            case .failure, .success:
                XCTFail("unexpected callback")
            }
        }) { _ in
            a2.fulfill()
        }
        dbl.commit()
        
        let b1 = expectation(description: "b1")
        let b2 = expectation(description: "b2")
        let b3 = expectation(description: "b3")
        let (commandBuffer2, encoder2) = self.hashKernel.newCommand()
        commandBuffer2.addCompletedHandler { _ in
            Thread.sleep(forTimeInterval: 0.2)
            b1.fulfill()
        }
        encoder2.endEncoding()
        dbl.enqueue(commandBuffer2, callback: { result in
            switch result {
            case .failure(JET.Error.stop):
                b3.fulfill()
            case .failure, .success:
                XCTFail("unexpected callback")
            }
        }) { _ in
            b2.fulfill()
        }
        
        dbl.stop(with: nil)
        wait(for: [ a1, a2, a3, b1, b2, b3, ], timeout: 2)
    }
}
