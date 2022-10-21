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
import XCTest
@testable import fltrJET

final class JETKernelTests: XCTestCase {
    var device: JET.MTLDeviceStates!
    let matchKernelName = "compare_xy_simd"
    
    override func setUp() {
        self.device = .init()
    }
    
    override func tearDown() {
        self.device = nil
    }
    
    func testMakeKernel() {
        XCTAssertEqual(JET.MatchKernel.functionName, self.matchKernelName)
        
        let kernel = expectation(description: "kernel")
        JET.MatchKernel.make(device: self.device) {
            switch $0 {
            case .success:
                break
            case .failure(let error):
                XCTFail(error.localizedDescription)
            }
            kernel.fulfill()
        }
        wait(for: [kernel], timeout: 1.0)
    }
    
    func testNewCommand() {
        var kernel: JET.MatchKernel! = nil
        let e = expectation(description: "")
        JET.MatchKernel.make(device: self.device) {
            kernel = try? $0.get()
            e.fulfill()
        }
        wait(for: [e], timeout: 1.0)
        
        XCTAssertNotNil(kernel)
        guard let encoder = kernel?.newCommand().1 else {
            XCTFail()
            return
        }
        encoder.endEncoding()
    }
    
    func testMakePipeline() {
        let compute = expectation(description: "compute")
        JET.ComputePipeline.makePipeline(device: self.device, functionName: self.matchKernelName) {
            switch $0 {
            case .success:
                break
            case .failure(.makeComputePipeline(wrapped: .some(let error))):
                XCTFail("error in makeComputePipeline pipeline \(error)")
            case .failure(let error):
                XCTFail("unexpected error: \(error)")
            }
            compute.fulfill()
        }
        wait(for: [compute], timeout: 1.0)
    }
    
    func testMakePipelineFail() {
        let compute = expectation(description: "compute")
        JET.ComputePipeline.makePipeline(device: self.device, functionName: self.matchKernelName + "****XCTFAIL****") {
            switch $0 {
            case .failure(.metalError):
                break
            case .success:
                XCTFail()
            case .failure(let error):
                XCTFail("unexpected error: \(error)")
            }
            compute.fulfill()
        }
        wait(for: [compute], timeout: 1.0)
    }
}
