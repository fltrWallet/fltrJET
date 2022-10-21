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
import FastrangeSipHash
@testable import fltrJET
import MetalKit
import XCTest

final class HashKernelTests: XCTestCase {
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

    var testData100: [[UInt8]] = {
        (0..<100).map { i in
            let j = (i % (JET.OpcodeBytes - 1)) + 1
            
            return (1..<j).map(UInt8.init)
        }
    }()
    
    var testKey: [UInt8] = (0..<16).map(UInt8.init)
    
    var testF: UInt64 = .max
    
    func setup(encoder: MTLComputeCommandEncoder,
               for buffers: JET.OpcodeBuffer,
               key: [UInt8],
               f: UInt64) {
        encoder.setBuffer(buffers.opcodes, offset: 0, index: 0)
        encoder.setBuffer(buffers.hashes, offset:0, index: 1)


        (key + f.littleEndianBytes)
        .withUnsafeBytes {
            precondition($0.count == 24)
            encoder.setBytes($0.baseAddress!, length: 24, index: 2)
        }
        
        let executionWidth = self.hashKernel.pipeline.threadExecutionWidth
        encoder.dispatchThreadgroups(buffers.mtlSize,
                                     threadsPerThreadgroup: MTLSize(width: executionWidth,
                                                                    height: 1,
                                                                    depth: 1))
        encoder.endEncoding()
    }
    
    // Using traditional CPU siphash + fastrange algorithm as solution fact
    func solution<S: Sequence, T: Sequence, U: Sequence>(for data: S,
                                                         key: U,
                                                         f: UInt64) -> [UInt32]
    where S.Element == T, T.Element == UInt8, U.Element == UInt8 {
        data.map { bytes in
            siphash(input: bytes, key: key)
        }
        .map { hash in
            fastrange(hash, f)
        }
        .map(UInt32.init(truncatingIfNeeded:))
    }

    func handleHashCompletion(cmd: MTLCommandBuffer,
                              result buffer: MTLBuffer,
                              count: Int) -> [UInt32] {
        let completion = expectation(description: "")
        var result: [UInt32] = []
        
        cmd.addCompletedHandler { _ in
            let pointer = buffer.contents().assumingMemoryBound(to: UInt32.self)
            for i in (0..<count) {
                result.append(pointer[i])
            }
            completion.fulfill()
        }
        cmd.commit()
        wait(for: [ completion ], timeout: 1.0)
        
        return result
    }
    
    func testHashSingle() {
        let testData = self.testData100[0...0]
        let testFact = self.solution(for: testData, key: self.testKey, f: self.testF)
        
        let buffers = JET.OpcodeBuffer.make(from: Array(testData),
                                            device: self.device,
                                            pipelineState: self.hashKernel.pipeline)
        let (cmd, encoder) = self.hashKernel.newCommand()
        self.setup(encoder: encoder,
                   for: buffers,
                   key: self.testKey,
                   f: self.testF)

        let result = self.handleHashCompletion(cmd: cmd,
                                               result: buffers.hashes,
                                               count: testData.count)
        XCTAssertEqual(result, testFact)
    }
    
    func testHashMulti() {
        let testFact = self.solution(for: self.testData100, key: self.testKey, f: self.testF)
        
        let buffers = JET.OpcodeBuffer.make(from: self.testData100,
                                            device: self.device,
                                            pipelineState: self.hashKernel.pipeline)
        let (cmd, encoder) = self.hashKernel.newCommand()
        self.setup(encoder: encoder,
                   for: buffers,
                   key: self.testKey,
                   f: self.testF)

        let result = self.handleHashCompletion(cmd: cmd,
                                               result: buffers.hashes,
                                               count: self.testData100.count)
        XCTAssertEqual(result, testFact)
    }
    
    func testHashRandom() {
        func randomData() -> [UInt8] {
            let count = Int.random(in: (1...23))
            
            return (1...count).map { _ in UInt8.random(in: .min ... .max) }
        }
        
        let randomCount = Int.random(in: 1000...10000)
        
        let testData = (1...randomCount).map { _ in
            randomData()
        }
        
        let randomKey = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        let randomF = UInt64.random(in: .min ... .max)
        
        let testFact = self.solution(for: testData,
                                     key: randomKey,
                                     f: randomF)
        
        let buffers = JET.OpcodeBuffer.make(from: testData,
                                            device: self.device,
                                            pipelineState: self.hashKernel.pipeline)
        let (cmd, encoder) = self.hashKernel.newCommand()
        self.setup(encoder: encoder,
                   for: buffers,
                   key: randomKey,
                   f: randomF)

        let result = self.handleHashCompletion(cmd: cmd,
                                               result: buffers.hashes,
                                               count: testData.count)
        XCTAssertEqual(result, testFact)
    }
}
