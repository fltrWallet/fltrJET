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

final class MatchKernelTests: XCTestCase {
    var device: MTLDevice!
    var jetDevice: JET.MTLDeviceStates!
    var matchKernel: JET.MatchKernel!
    
    override func setUp() {
        self.device = MTLCreateSystemDefaultDevice()
        self.jetDevice = .init(device: self.device)
        
        let kernel = expectation(description: "kernel")
        JET.MatchKernel.make(device: self.jetDevice) {
            switch $0 {
            case .success(let kernel):
                self.matchKernel = kernel
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
        self.matchKernel = nil
    }
    
    struct MatchTestData {
        let hashes: MTLBuffer
        let filters: MTLBuffer
        let output: MTLBuffer
        let mtlSize: MTLSize
        
        func setup(encoder: MTLComputeCommandEncoder,
                   threadsPerThreadgroup: MTLSize) {
            encoder.setBuffer(self.hashes, offset: 0, index: 0)
            encoder.setBuffer(self.filters, offset: 0, index: 1)
            encoder.setBuffer(self.output, offset: 0, index: 2)
            encoder.dispatchThreadgroups(self.mtlSize,
                                         threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()
        }
    }
    
    func makeBuffers(x: [UInt32], y: [UInt32]) -> MatchTestData {
        var x = x
        let threadGroupWidth = JET.ThreadGroupWidth
        let widthFactor = moduloExtend(&x, modulo: threadGroupWidth, with: .max)
        let xBuffer = self.device.makeBuffer(length: JET.FilterBufferSize, options: .storageModeShared)!
        xBuffer.write(x)
        
        var y = y
        let threadGroupHeight = self.matchKernel.height()
        let heightFactor = moduloExtend(&y, modulo: threadGroupHeight, with: .min)
        let yBuffer = self.device.makeBuffer(length: JET.FilterBufferSize, options: .storageModeShared)!
        yBuffer.write(y)

        let outputBuffer = self.device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)!
        
        let mtlSize = MTLSizeMake(widthFactor, heightFactor, 1)

        return MatchTestData(hashes: xBuffer,
                             filters: yBuffer,
                             output: outputBuffer,
                             mtlSize: mtlSize)
    }
    
    func handleMatchCompletion(cmd: MTLCommandBuffer,
                               result buffer: MTLBuffer) -> UInt32 {
        let completion = expectation(description: "")
        var result = UInt32.max
        
        cmd.addCompletedHandler { _ in
            let pointer = buffer.contents().assumingMemoryBound(to: UInt32.self)
            result = pointer[0]
            completion.fulfill()
        }
        cmd.commit()
        wait(for: [ completion ], timeout: 1.0)
        
        return result
    }
    
    func testMatchSingle() {
        let (cmd, encoder) = self.matchKernel.newCommand()
        let testData = self.makeBuffers(x: [ 1, ],
                                        y: [ 1, ])
        
        let threadPerThreadgroup = MTLSizeMake(JET.ThreadGroupWidth,
                                               self.matchKernel.height(),
                                               1)
        testData.setup(encoder: encoder,
                       threadsPerThreadgroup: threadPerThreadgroup)
        let result = self.handleMatchCompletion(cmd: cmd, result: testData.output)
        XCTAssertGreaterThan(result, 0)
    }
    
    func testMissSingle() {
        let (cmd, encoder) = self.matchKernel.newCommand()
        let testData = self.makeBuffers(x: [ 1, ],
                                        y: [ 2, ])
        
        let threadPerThreadgroup = MTLSizeMake(JET.ThreadGroupWidth,
                                               self.matchKernel.height(),
                                               1)
        testData.setup(encoder: encoder,
                       threadsPerThreadgroup: threadPerThreadgroup)
        let result = self.handleMatchCompletion(cmd: cmd, result: testData.output)
        XCTAssertEqual(result, 0)
    }
    
    func testMatchMulti() {
        let x = (0..<1024).map { 1000 + UInt32($0) }
        var y = (0..<512).map { 10_000 + UInt32($0) }
        y.append(1100)
        y.append(contentsOf: (0..<512).map { 10_000 + UInt32($0) })
        
        let (cmd, encoder) = self.matchKernel.newCommand()
        let testData = self.makeBuffers(x: x,
                                        y: y)
        
        let threadPerThreadgroup = MTLSizeMake(JET.ThreadGroupWidth,
                                               self.matchKernel.height(),
                                               1)
        testData.setup(encoder: encoder,
                       threadsPerThreadgroup: threadPerThreadgroup)
        let result = self.handleMatchCompletion(cmd: cmd, result: testData.output)
        XCTAssertGreaterThan(result, 0)
    }
    
    func testMissMulti() {
        let x = (0..<1024).map { 1000 + UInt32($0) }
        let y = (0..<2048).map { 10_000 + UInt32($0) }
        
        let (cmd, encoder) = self.matchKernel.newCommand()
        let testData = self.makeBuffers(x: x,
                                        y: y)
        
        let threadPerThreadgroup = MTLSizeMake(JET.ThreadGroupWidth,
                                               self.matchKernel.height(),
                                               1)
        testData.setup(encoder: encoder,
                       threadsPerThreadgroup: threadPerThreadgroup)
        let result = self.handleMatchCompletion(cmd: cmd, result: testData.output)
        XCTAssertEqual(result, 0)
    }

    func testMatchRandom() {
        for _ in (1...100) {
            let x = Set((0..<2000).map { _ in UInt32.random(in: 1 ... 10_000_000) })
            let y = Set((0..<2000).map { _ in UInt32.random(in: 1 ... 10_000_000) })
            let solution = x.intersection(y).count > 0
            
            let (cmd, encoder) = self.matchKernel.newCommand()
            let testData = self.makeBuffers(x: Array(x),
                                            y: Array(y))
            
            let threadPerThreadgroup = MTLSizeMake(JET.ThreadGroupWidth,
                                                   self.matchKernel.height(),
                                                   1)
            testData.setup(encoder: encoder,
                           threadsPerThreadgroup: threadPerThreadgroup)
            let result = self.handleMatchCompletion(cmd: cmd, result: testData.output)
            XCTAssertEqual(result > 0, solution)
        }
    }
}
