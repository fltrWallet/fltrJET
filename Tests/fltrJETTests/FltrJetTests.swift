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
import fltrECC
import fltrECCTesting
import FastrangeSipHash
import fltrJET
import fltrTx
import XCTest

final class FltrJetTests: XCTestCase {
    var matcher: JETMatcher!
    var key: [UInt8] = (0..<16).map { $0 }
    let f: UInt64 = (1 << 63) + 1
    
    override func setUp() {
        self.matcher = .init()
    }
    
    override func tearDown() {
        self.matcher.stop()
        self.matcher = nil
    }
    
    func start() {
        let start = expectation(description: "start")
        self.matcher.start {
            switch $0 {
            case .success:
                break
            case .failure:
                XCTFail()
            }
            start.fulfill()
        }
        wait(for: [start], timeout: 2.0)
    }
    
    func testUpdate() {
        self.start()
        
        XCTAssertFalse(self.matcher.testIsBuffered)
        XCTAssertFalse(self.matcher.testIsUpdateRequested)
        self.matcher.reload(opcodes: self.opcodes(count: 100))
        XCTAssertFalse(self.matcher.testIsBuffered)
        XCTAssertTrue(self.matcher.testIsUpdateRequested)
    }
    
    func testMatchSingle() {
        self.start()
        let keys = self.opcodes(count: 1)
        self.matcher.reload(opcodes: keys)

        let control = filterMatch(opcodes: keys[0], key: self.key, f: self.f)
        let match = expectation(description: "match")
        self.matcher.match(filter: [control], key: self.key, f: self.f) {
            switch $0 {
            case .success(let result):
                XCTAssertTrue(result)
            case .failure(let error):
                XCTFail("error from matcher.match call: \(error)")
            }
            match.fulfill()
        }
        wait(for: [match], timeout: 1.0)
    }
    
    func testMissSingle() {
        self.start()
        let keys = self.opcodes(count: 1)
        self.matcher.reload(opcodes: keys)

        let control = UInt32(0)
        let miss = expectation(description: "miss")
        self.matcher.match(filter: [control], key: self.key, f: self.f) {
            switch $0 {
            case .success(let result):
                XCTAssertFalse(result)
            case .failure:
                XCTFail()
            }
            miss.fulfill()
        }
        wait(for: [miss], timeout: 1.0)
    }
    
    func testMultiIterative() {
        let keyCount = 1025
        let tests = 257
        
        let filters: [UInt32] = (0..<1023).map { _ in .max }
        let keys = self.opcodes(count: keyCount)
        self.matcher.reload(opcodes: keys)
        self.start()
        
        func makeTests(matching: Bool, first: Bool, legacy: Bool) -> [XCTestExpectation] {
            var expectations: [XCTestExpectation] = []
            (0..<tests).forEach { testIndex in
                let e = expectation(description: "match")
                expectations.append(e)
                
                let filterMatching = matching
                    ? filterMatch(opcodes: keys[legacy ? testIndex % keyCount : (testIndex % keyCount) * 2],
                                  key: self.key, f: self.f)
                    : UInt32.max
                self.matcher.match(
                    filter: first
                        ? [ filterMatching ] + filters
                        : filters + [ filterMatching ],
                    key: self.key,
                    f: self.f
                ) {
                    switch $0 {
                    case .success(let result):
                        XCTAssert(result == matching)
                        e.fulfill()
                    case .failure(let error):
                        XCTFail("error \(error)")
                    }
                }
            }
            
            return expectations
        }

        let ref = Date()
        let e1 = makeTests(matching: false, first: false, legacy: false)
        wait(for: e1, timeout: 2)
        
        let e2 = makeTests(matching: false, first: false, legacy: true)
        wait(for: e2, timeout: 2)
        
        let e3 = makeTests(matching: false, first: true, legacy: false)
        wait(for: e3, timeout: 2)
        
        let e4 = makeTests(matching: false, first: true, legacy: true)
        wait(for: e4, timeout: 2)
        
        let e5 = makeTests(matching: true, first: false, legacy: false)
        wait(for: e5, timeout: 2)
        
        let e6 = makeTests(matching: true, first: false, legacy: true)
        wait(for: e6, timeout: 2)
        
        let e7 = makeTests(matching: true, first: true, legacy: false)
        wait(for: e7, timeout: 2)
        
        let e8 = makeTests(matching: true, first: true, legacy: true)
        wait(for: e8, timeout: 2)
        print("total time", ref.distance(to: Date()))
    }
    
    /* DOES NOT WORK, UNCLEAR INTENT
    func testStop() throws {
        let filters: [UInt32] = (0..<1024).map { _ in .max }
        let keys = self.opcodes(count: 32)
        self.matcher.reload(opcodes: keys)
        
        self.start()

        let sem = DispatchSemaphore(value: 0)
        let e = expectation(description: "stop")
        var stopCount = 0
        (0..<20).forEach { testIndex in
            self.matcher.match(filter: filters, key: self.key, f: self.f) {
                if testIndex == 0 {
                    sem.wait()
                }
                if testIndex == 19 { //last
                    sem.signal()
                    e.fulfill()
                }

                switch $0 {
                case .success(false): break
                case .success(true): XCTFail()
                case .failure(JET.Error.stop):
                    stopCount += 1
                case .failure: XCTFail()
                }
            }
        }
        self.matcher.stop()
        sem.signal()
        wait(for: [e], timeout: 2)
        XCTAssertEqual(stopCount, 19)
        
        self.matcher.match(filter: filters, key: self.key, f: self.f) {
            switch $0 {
            case .success: XCTFail()
            case .failure: break
            }
        }
    }*/
    
    func testMatchBeforeStartFailure() {
        self.matcher.match(filter: [ .max ], key: self.key, f: self.f) {
            switch $0 {
            case .failure: break
            case .success: XCTFail()
            }
        }
    }
    
    func testMatchMaxFilters() {
        let filtersAlmostFull: [UInt32] = (1..<JET.FilterCountCapacity).map { UInt32($0) }

        self.start()
        let keys = self.opcodes(count: 1)
        self.matcher.reload(opcodes: keys)

        let filterMatching = filterMatch(opcodes: keys[0], key: self.key, f: self.f)
        let filtersFull = filtersAlmostFull + [filterMatching]
        let match = expectation(description: "match")
        self.matcher.match(filter: filtersFull, key: self.key, f: self.f) {
            switch $0 {
            case .success(let result):
                XCTAssertTrue(result)
            case .failure:
                XCTFail()
            }
            match.fulfill()
        }
        wait(for: [match], timeout: 1.0)
    }
    
    func testRekey() {
        self.start()
        let keys = self.opcodes(count: 65)
        self.matcher.reload(opcodes: keys)
        let filterMatching = filterMatch(opcodes: keys[0], key: self.key, f: self.f)
        let match = expectation(description: "match")
        self.matcher.match(filter: [ .max, filterMatching, .zero, ], key: self.key, f: self.f) {
            switch $0 {
            case .success(let result):
                XCTAssertTrue(result)
            case .failure:
                XCTFail()
            }
            match.fulfill()
        }
        wait(for: [match], timeout: 1.0)
        
        let keysDropFirst = Array(keys.dropFirst())
        self.matcher.reload(opcodes: keysDropFirst)
        let drop = expectation(description: "match")
        self.matcher.match(filter: [ .max, filterMatching, .zero, ], key: self.key, f: self.f) {
            switch $0 {
            case .success(let result):
                XCTAssertFalse(result)
            case .failure:
                XCTFail()
            }
            drop.fulfill()
        }
        wait(for: [drop], timeout: 1.0)

        self.matcher.reload(opcodes: keys)
        let match2 = expectation(description: "match")
        self.matcher.match(filter: [ .max, filterMatching, .zero, ], key: self.key, f: self.f) {
            switch $0 {
            case .success(let result):
                XCTAssertTrue(result)
            case .failure:
                XCTFail()
            }
            match2.fulfill()
        }
        wait(for: [match2], timeout: 1.0)
    }
    
    func keys(count: Int) -> [PublicKeyHash] {
        (1...count).map {
            return PublicKeyHash(DSA.PublicKey(Point($0)))
        }
    }
    
    func opcodes(count: Int) -> [[UInt8]] {
        let publicKeyHashes = self.keys(count: count)
        
        let legacy: [[UInt8]] = publicKeyHashes
        .map {
            $0.scriptPubKeyLegacyWPKH
        }
        let segwit: [[UInt8]] = publicKeyHashes
        .map {
            $0.scriptPubKeyWPKH
        }
        
        return legacy + segwit
    }
}

func filterMatch(opcodes bytes: [UInt8], key: [UInt8], f: UInt64) -> UInt32 {
    let bytesSiphash = siphash(input: bytes, key: key)
    let hash = fastrange(bytesSiphash, f)
    return UInt32(truncatingIfNeeded: hash)
}
