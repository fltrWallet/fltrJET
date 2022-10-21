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
import class Foundation.Bundle
import MetalKit
import struct NIOCore.CircularBuffer
import NIOConcurrencyHelpers
import HaByLo
import fltrTx

public enum JET {
    public static let ThreadGroupWidth: Int = 8
    public static func SimdHeight(_ pipeline: MTLComputePipelineState) -> Int {
        let simdGroup = pipeline.threadExecutionWidth
        return simdGroup / Self.ThreadGroupWidth
    }
    public static let OpcodeBytes: Int = 40
    public static let FilterCountCapacity: Int = 16192
    public static let FilterBufferSize: Int = Self.FilterCountCapacity * MemoryLayout<UInt32>.stride
    public static let QueueCapacity: Int = 16
}

public final class JETMatcher {
    @usableFromInline
    var stateMachine: JET.StateMachine = try! .init()
    
    @usableFromInline
    let lock: NIOLock = .init()
    
    public init() {}
    
    deinit {
        guard case .stop = self.stateMachine.state
        else {
            logger.error("JETMatcher - ❌ DEINIT WITHOUT STOP")
            preconditionFailure()
        }
    }
}

extension JET {
    @usableFromInline
    final class OpcodeBuffer {
        let opcodes: MTLBuffer
        let hashes: MTLBuffer
        let hashesWidth: Int
        let mtlSize: MTLSize
        let count: Int

        @usableFromInline
        init(opcodes: MTLBuffer,
             hashes: MTLBuffer,
             hashesWidth: Int,
             mtlSize: MTLSize,
             count: Int) {
            self.opcodes = opcodes
            self.hashes = hashes
            self.hashesWidth = hashesWidth
            self.mtlSize = mtlSize
            self.count = count
        }

        
        static func make(from bytes: [[UInt8]],
                         device: MTLDevice,
                         pipelineState: MTLComputePipelineState) -> Self {
            var opcodes: [[UInt8]] = bytes.map {
                assert($0.count < JET.OpcodeBytes)
                return $0.extend(to: JET.OpcodeBytes, opcodeCount: $0.count)
            }
            
            let totalCount = opcodes.count
            let executionWidth = pipelineState.threadExecutionWidth

            let invalidOpcodes: [UInt8] = (1..<JET.OpcodeBytes).map { _ in UInt8(0xff) } + [ 22 ]
            let quotient = moduloExtend(&opcodes, modulo: executionWidth, with: invalidOpcodes)
            assert(quotient > 0)
            
            let (hashesQuotient, remainder) = totalCount.quotientAndRemainder(dividingBy: JET.ThreadGroupWidth)
            let hashesWidth = remainder > 0 ? hashesQuotient + 1 : hashesQuotient
            
            let totalBytes = Array(opcodes.joined())

            #if DEBUG
            let hashesOptional = device.makeBuffer(
                length: max(opcodes.count, hashesWidth * JET.ThreadGroupWidth) * MemoryLayout<UInt32>.stride,
                options: .storageModeShared
            )
            #else
            let hashesOptional = device.makeBuffer(
                length: max(opcodes.count, hashesWidth * JET.ThreadGroupWidth) * MemoryLayout<UInt32>.stride,
                options: .storageModePrivate
            )
            #endif

            guard let opcodeBuffer = totalBytes.withUnsafeBytes({
                device.makeBuffer(bytes: $0.baseAddress!, length: totalBytes.count, options: .storageModeShared)
            }),
            let hashes = hashesOptional
            else {
                preconditionFailure("Error: nil result calling device.makeBuffer(length:options:)")
            }

            let mtlSize = MTLSize(width: quotient, height: 1, depth: 1)
            
            return .init(opcodes: opcodeBuffer,
                         hashes: hashes,
                         hashesWidth: hashesWidth,
                         mtlSize: mtlSize,
                         count: totalCount)
        }
    }
    
    @usableFromInline
    struct StateMachine {
        @usableFromInline
        var state: StateEnum
        
        @usableFromInline
        var queue: CircularBuffer<QueueItem> = .init(initialCapacity: JET.QueueCapacity)
        
        @usableFromInline
        var updateOpcodes: [[UInt8]]? = nil
        
        @usableFromInline
        var opcodeBuffer: OpcodeBuffer? = nil
        
        init() throws {
            self.state = .preinit(try .init())
        }
    }
}

// MARK: Matcher
extension JETMatcher {
    @inlinable
    public func match(filter: [UInt32],
                      key: [UInt8],
                      f: UInt64,
                      callback: @escaping (Result<Bool, JET.Error>) -> Void) {
        let enqueueHandler: (Result<JET.Action, JET.Error>) -> Void = {
            switch $0 {
            case .success(.await(let result)):
                callback(.success(result))
                self.execute(.await(result: result))
            case .success(.stop(.metalError(let message))): // Metal error from commandBuffer completion handler
                self.execute(.stop(with: .metalError(message)))
            case .success(let action):
                preconditionFailure("unhandled callback action \(action)")
            case .failure(let error):
                callback(.failure(error))
            }
        }
        
        let action = self.lock.withLock {
            self.stateMachine.enqueue(filter: filter, key: key, f: f, callback: enqueueHandler)
        }
        self.execute(action)
    }
    
    @usableFromInline
    func execute(_ action: JET.Action) -> Void {
        do {
            let next: JET.Action
            
            switch action {
            case .await:
                next = try self.lock.withLock {
                    try self.stateMachine.checkQueue()
                }
            case .execute:
                next = try self.lock.withLock {
                    try self.stateMachine.execute()
                }
            case .started(let kernels):
                next = try self.lock.withLock {
                    try self.stateMachine.provide(kernels: kernels)
                }
            case .stop(let error):
                next = self.lock.withLock {
                    self.stateMachine.stop(with: error)
                }
            case .asynch, .continue:
                return
            }
            
            self.execute(next)
        } catch {
            switch error {
            case let error as JET.Error:
                self.execute(.stop(with: error))
            default:
                preconditionFailure()
            }
        }
    }
    
    @inlinable
    public func start(_ callback: ((Result<Void, JET.Error>) -> Void)? = nil) {
        let startHandler: (Result<JET.Action, JET.Error>) -> Void = {
            switch $0 {
            case .success(let action):
                defer { callback?(.success(())) }
                self.execute(action)
            case .failure(let error):
                defer { callback?(.failure(error)) }
                self.execute(.stop(with: error))
            }
        }
        
        let action = self.lock.withLock {
            self.stateMachine.start(startHandler)
        }
        
        self.execute(action)
    }
    
    @inlinable
    public func reload(opcodes: [[UInt8]]) {
        self.lock.withLock {
            self.stateMachine.updateOpcodes = opcodes
        }
    }
    
    @inlinable
    public func stop() {
        self.lock.withLockVoid {
            _ = self.stateMachine.stop(with: nil)
        }
    }
}

// MARK: StateMachine
extension JET.StateMachine {
    @usableFromInline
    enum StateEnum {
        case preinit(JET.PreinitState)
        case idle(JET.IdleState)
        case busy(JET.BusyState)
        case stop(JET.StopState)
        
        var device: MTLDevice {
            switch self {
            case .busy(let state):
                return state.device.device
            case .idle(let state):
                return state.device.device
            case .preinit(let state):
                return state.device.device
            case .stop(let state):
                return state.device.device
            }
        }
        
        
        @usableFromInline
        func _kernels(function: StaticString = #function) throws -> [JETKernel] {
            func checkKernelsEmpty(_ in: [JETKernel]) throws -> [JETKernel] {
                guard let _ = `in`.first
                else { throw JET.Error.kernelsEmpty }
                return `in`
            }
            
            switch self {
            case .busy(let state):
                return try checkKernelsEmpty(state.kernels)
            case .idle(let state):
                return try checkKernelsEmpty(state.kernels)
            case .preinit, .stop:
                throw JET.Error.illegalState(state: String(describing: self), event: function)
            }
        }
        
        func firstKernel(function: StaticString = #function) throws -> JETKernel {
            try self._kernels(function: function).first!
        }
        
        func matchKernel(function: StaticString = #function) throws -> JET.MatchKernel {
            let kernels = try self._kernels(function: function)
            
            guard let found = kernels.compactMap({ $0 as? JET.MatchKernel }).first
            else { throw JET.Error.kernelsEmpty }
            
            return found
        }
    }
    
    @usableFromInline
    func start(_ callback: @escaping (Result<JET.Action, JET.Error>) -> Void) -> JET.Action {
        switch self.state {
        case .preinit(let state):
            JET.MatchKernel.make(device: state.device) {
                switch $0 {
                case .success(let matchKernel):
                    JET.HashKernel.make(device: state.device) {
                        switch $0 {
                        case .success(let hashKernel):
                            callback(.success(.started([ hashKernel, matchKernel, ])))
                        case .failure(let error):
                            callback(.failure(error))
                        }
                    }
                case .failure(let error):
                    callback(.failure(error))
                }
            }
            return .asynch
        case .busy, .idle, .stop:
            callback(.failure(JET.Error.illegalState(self)))
            return .continue
        }
    }
    
    @usableFromInline
    mutating func provide(kernels: [JETKernel]) throws -> JET.Action {
        switch self.state {
        case .preinit(let state):
            assert(self.queue.isEmpty)
            self.state = try .idle(JET.IdleState(state, kernels: kernels))
            return .continue
        case .busy, .idle, .stop:
            throw JET.Error.illegalState(self)
        }
    }
    
    @usableFromInline
    func encode(queueItem: JET.QueueItem,
                double buffer: JET.DoubleBuffer,
                output: MTLBuffer) throws {
        // MARK: State setup
        let firstKernel: JETKernel = try self.state.firstKernel()
        let matchKernel: JET.MatchKernel = try self.state.matchKernel()
        guard let opcodeBuffer = self.opcodeBuffer
        else { throw JET.Error.internalError }
        let (commandBuffer, encoder) = firstKernel.newCommand()
       
        buffer.enqueue(commandBuffer, callback: queueItem.callback) { mtlBuffer in
            // MARK: ENCODE: hash_all
            encoder.setBuffer(opcodeBuffer.opcodes, offset: 0, index: 0)
            encoder.setBuffer(opcodeBuffer.hashes, offset: 0, index: 1)
            (queueItem.key + queueItem.f.littleEndianBytes)
            .withUnsafeBytes {
                encoder.setBytes($0.baseAddress!, length: 24, index: 2)
            }
            encoder.dispatchThreadgroups(opcodeBuffer.mtlSize,
                                         threadsPerThreadgroup: MTLSize(
                                            width: firstKernel.pipeline.threadExecutionWidth,
                                            height: 1,
                                            depth: 1))
            
            // MARK: WRITE: MTLBuffer
            let threadGroupHeight = matchKernel.height()
            var filters = queueItem.filters
            let heightFactor = moduloExtend(&filters, modulo: threadGroupHeight)
            mtlBuffer.write(filters)
            
            // MARK: ENCODE: match_xy
            let width = opcodeBuffer.hashesWidth
            let mtlSize = MTLSize(width: width, height: heightFactor, depth: 1)
            encoder.setComputePipelineState(matchKernel.pipeline)
            encoder.setBuffer(opcodeBuffer.hashes, offset: 0, index: 0)
            encoder.setBuffer(mtlBuffer, offset:0, index: 1)
            encoder.setBuffer(output, offset: 0, index: 2)
            encoder.dispatchThreadgroups(mtlSize,
                                         threadsPerThreadgroup: MTLSize(width: JET.ThreadGroupWidth,
                                                                        height: matchKernel.height(),
                                                                        depth: 1))
            encoder.endEncoding()

            commandBuffer.addCompletedHandler {
                if let error = JET.log()($0) {
                    queueItem.callback(.success(.stop(with: error)))
                    return
                }
                let result = output.contents().assumingMemoryBound(to: UInt32.self)
                var outcome: Bool = false
                if result[0] > 0 {
                    outcome = true
                }
                queueItem.callback(.success(.await(result: outcome)))
            }
        }
    }
    
    @usableFromInline
    mutating func enqueue(filter: [UInt32],
                          key: [UInt8],
                          f: UInt64,
                          callback: @escaping (Result<JET.Action, JET.Error>) -> Void) -> JET.Action {
        assert(key.count == 16)
        let firstKernel: Result<JETKernel, JET.Error> = Result { try self.state.firstKernel() }.mapError { $0 as! JET.Error }
        switch firstKernel {
        case .success(let firstKernel):
            if let opcodes = self.updateOpcodes {
                self.opcodeBuffer = JET.OpcodeBuffer.make(from: opcodes,
                                                          device: firstKernel.device,
                                                          pipelineState: firstKernel.pipeline)
                self.updateOpcodes = nil
            }
        case .failure(let error):
            callback(.failure(error))
            return .stop(with: error)
        }
        
        let enqueue = JET.QueueItem(filters: filter,
                                    key: key,
                                    f: f,
                                    callback: callback)
        
        switch self.state {
        case .idle(let state):
            let result: Result<Void, JET.Error> = Result {
                try self.encode(queueItem: enqueue, double: state.buffer, output: state.output)
            }
            .mapError {
                $0 as! JET.Error
            }

            switch result {
            case .success:
                self.state = .busy(JET.BusyState(state))
                return .execute
            case .failure(let error):
                defer { callback(.failure(error)) }
                return .stop(with: error)
            }
        case .busy(let state):
            if state.buffer.full() {
                self.queue.append(enqueue)
                trace(event: "queue depth: \(self.queue.count)", number: self.queue.count)
                return .continue
            } else { //double buffer
                let result: Result<Void, JET.Error> = Result {
                    try self.encode(queueItem: enqueue, double: state.buffer, output: state.output)
                }
                .mapError {
                    $0 as! JET.Error
                }

                switch result {
                case .success:
                    return .continue
                case .failure(let error):
                    defer { callback(.failure(error)) }
                    return .stop(with: error)
                }
            }
        case .preinit, .stop:
            let error = JET.Error.illegalState(self)
            defer { callback(.failure(error)) }
            return .stop(with: error)
        }
    }
    
    mutating func execute() throws -> JET.Action {
        let firstKernel = try self.state.firstKernel()
        if let opcodes = self.updateOpcodes {
            self.opcodeBuffer = JET.OpcodeBuffer.make(from: opcodes,
                                                      device: firstKernel.device,
                                                      pipelineState: firstKernel.pipeline)
            self.updateOpcodes = nil
        }
        
        switch self.state {
        case .busy(let state):
            // 1. Commit current
            state.buffer.commit()
            
            // check queue
            guard let first = self.queue.popFirst()
            else { break }
            
            // 2. Encode next command
            try self.encode(queueItem: first, double: state.buffer, output: state.output)
        case .idle, .preinit, .stop:
            throw JET.Error.illegalState(self)
        }
        
        return .asynch
    }
    
    mutating func checkQueue() throws -> JET.Action {
        func resetOutput(_ buffer: MTLBuffer) {
            let out = buffer.contents().assumingMemoryBound(to: UInt32.self)
            out[0] = 0
        }
        
        switch self.state {
        case .busy(let state):
            resetOutput(state.output)
            switch (self.queue.isEmpty, state.buffer.idle()) {
            case (false, _),
                 (true, false):
                return .execute
            case (true, true):
                self.state = .idle(JET.IdleState(state))
                return .continue
            }
        case .preinit, .idle:
            throw JET.Error.illegalState(self)
        case .stop:
            return .continue
        }
    }
    
    @usableFromInline
    mutating func stop(with error: JET.Error?) -> JET.Action {
        let copy = self.queue.map(\.callback)
        self.queue.removeAll()

        var callBufferStopDeferred: (() -> Void)? = nil
        switch self.state {
        case .busy(let state):
            self.state = .stop(JET.StopState(device: state.device))
            callBufferStopDeferred = {
                state.buffer.stop(with: error)
            }
        case .idle(let state):
            self.state = .stop(JET.StopState(device: state.device))
        case .preinit(let state):
            self.state = .stop(JET.StopState(device: state.device))
        case .stop:
            break
        }

        self.opcodeBuffer = nil
        self.updateOpcodes = nil

        copy.forEach { callback in
            callback(.failure(error ?? .stop))
        }
        callBufferStopDeferred?()

        if let error = error {
            switch error {
            case JET.Error.illegalState(state: "StateEnum.stop", _):
                break // stopped in the middle of work
            default:
                logger.error("JETMatcher \(#function) - 💥 Stopping with ERROR \(error)")
            }
        }
        
        return .continue
    }
}

extension JET {
    @usableFromInline
    final class DoubleBuffer {
        private var head: Int
        private var queue: Int
        private var encodedCommand: Optional<MTLCommandBuffer>
        private var buffers: [MTLBuffer]
        private let lock: NIOLock
        private var callbacks: CircularBuffer<((Result<JET.Action, JET.Error>) -> Void)> = .init(initialCapacity: 2)
        
        private init(head: Int = 0,
                     encodedCommand: Optional<MTLCommandBuffer> = .none,
                     buffers: [MTLBuffer]) {
            self.head = head
            self.queue = 0
            self.encodedCommand = encodedCommand
            self.lock = NIOLock()
            self.buffers = buffers
        }
        
        private func indexAndQueue() -> Int {
            assert(self.head == 0 || self.head == 1)
            assert(self.queue < 2)
            defer { self.queue += 1}

            return (self.head + self.queue) & 0b1
        }
        
        private func dequeueAndNext() {
            assert(self.head == 0 || self.head == 1)
            assert(self.queue <= 2)
            
            self.queue -= 1
            self.head = (self.head ^ 0b1) & 0b1
            assert(self.queue >= 0)
        }

        func full() -> Bool {
            let queue = self.lock.withLock { self.queue }
            
            return queue == 2 || self.encodedCommand != nil ? true : false
        }
        
        func idle() -> Bool {
            let queue = self.lock.withLock { self.queue }

            return queue == 0 ? true : false
        }
        
        func stop(with error: JET.Error?) {
            let callbacks: CircularBuffer<((Result<JET.Action, JET.Error>) -> Void)> = self.lock.withLock {
                defer { self.callbacks.removeAll() }
                
                return self.callbacks
            }
            
            
            callbacks.forEach {
                $0(.failure(error ?? .stop))
            }
            
            // empty call queue
            if let _ = self.encodedCommand {
                self.commit()
            }
        }
        
        static func makeBuffers(using device: MTLDevice) throws -> Self {
            guard let mtlBufferA = device.makeBuffer(length: JET.FilterBufferSize, options: .storageModeShared),
                  let mtlBufferB = device.makeBuffer(length: JET.FilterBufferSize, options: .storageModeShared)
            else { throw JET.Error.metalError("Error: nil result calling device.makeBuffer(length:options:)") }
            
            return self.init(buffers: [ mtlBufferA, mtlBufferB, ])
        }
        
        private func commandCompleted(_ any: Any? = nil) {
            self.lock.withLockVoid {
                _ = self.callbacks.popFirst()
                self.dequeueAndNext()
            }
        }

        func enqueue(_ commandBuffer: MTLCommandBuffer,
                     function: StaticString = #function,
                     file: StaticString = #fileID,
                     line: Int = #line,
                     callback: @escaping (Result<JET.Action, JET.Error>) -> Void,
                     enqueuer: (MTLBuffer) -> ()) {
            assert(self.encodedCommand == nil)
            
            commandBuffer.addCompletedHandler(self.commandCompleted(_:))

            let bufferIndex = self.lock.withLock { self.indexAndQueue() }
            let buffer = self.buffers[bufferIndex]
            enqueuer(buffer)
            self.encodedCommand = commandBuffer
            
            self.lock.withLockVoid {
                self.callbacks.append(callback)
            }
        }
        
        func commit(function: StaticString = #function,
                    file: StaticString = #fileID,
                    line: Int = #line) {
            let encodedCommand: MTLCommandBuffer? = self.lock.withLock {
                assert(self.encodedCommand != nil)
                assert(self.head == 0 || self.head == 1)
                assert(self.queue >= 1 && self.queue <= 2)
                let encodedCommand = self.encodedCommand
                self.encodedCommand = nil
                return encodedCommand
            }

            encodedCommand!.commit()
        }
    }
}

// MARK: Metal Setup
public protocol JETKernel {
    var computePipeline: JET.ComputePipeline { get }
    static var functionName: String { get }
    
    init(_: JET.ComputePipeline)
}

extension JETKernel {
    var commandQueue: MTLCommandQueue {
        self.computePipeline.device.commandQueue
    }
    
    var device: MTLDevice {
        self.computePipeline.device.device
    }

    var pipeline: MTLComputePipelineState {
        self.computePipeline.pipeline
    }
    
    
    static func make(device: JET.MTLDeviceStates,
                     callback: @escaping (Result<Self, JET.Error>) -> Void) {
        JET.ComputePipeline.makePipeline(device: device,
                                         functionName: Self.functionName) { result in
            switch result {
            case .success(let pipeline):
                callback(.success(.init(pipeline)))
            case .failure(let error):
                callback(.failure(error))
            }
        }
    }
    
    func newCommand() -> (MTLCommandBuffer, MTLComputeCommandEncoder) {
        let descriptor = MTLCommandBufferDescriptor()
        descriptor.errorOptions = .encoderExecutionStatus
        let commandBuffer = self.commandQueue.makeCommandBuffer(descriptor: descriptor)!
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(self.pipeline)

        return (commandBuffer, encoder)
    }
}

extension JET {
    final class MTLDeviceStates {
        let device: MTLDevice
        let library: MTLLibrary
        let commandQueue: MTLCommandQueue
        
        init(device: MTLDevice, library: MTLLibrary, commandQueue: MTLCommandQueue) {
            self.device = device
            self.library = library
            self.commandQueue = commandQueue
        }
        
        convenience init(device: MTLDevice) {
            #if canImport(fltrJET)
            let library = try! device.makeDefaultLibrary(bundle: Bundle.module)
            #else
            let library = device.makeDefaultLibrary()!
            #endif
            
            self.init(device: device, library: library, commandQueue: device.makeCommandQueue()!)
        }
        
        convenience init() {
            self.init(device: MTLCreateSystemDefaultDevice()!)
        }
    }
    
    public final class ComputePipeline {
        let device: MTLDeviceStates
        let pipeline: MTLComputePipelineState
        
        init(device: MTLDeviceStates, pipeline: MTLComputePipelineState) {
            self.device = device
            self.pipeline = pipeline
        }
        
        static func makePipeline(device: MTLDeviceStates,
                                 functionName: String,
                                 callback: @escaping (Result<ComputePipeline, JET.Error>) -> Void) {
            guard let function = device.library.makeFunction(name: functionName)
            else {
                callback(.failure(.metalError("illegal functionName: \(functionName)")))
                return
            }

            // Testing optimization using pipeline descriptor to specify
            // threadGroupSizeIsMultipleOfThreadExecutionWidth
            let mtlComputePipelineDescriptor = MTLComputePipelineDescriptor()
            mtlComputePipelineDescriptor.computeFunction = function
            mtlComputePipelineDescriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true
            device.device.makeComputePipelineState(descriptor: mtlComputePipelineDescriptor, options: [])
            { pipeline, _, error in
                switch (pipeline, error) {
                case (.none, .none):
                    callback(.failure(JET.Error.makeComputePipeline(wrapped: nil)))
                case (.none, .some(let error)):
                    callback(.failure(JET.Error.makeComputePipeline(wrapped: error)))
                case (.some(let pipeline), .none):
                    callback(.success(ComputePipeline(device: device, pipeline: pipeline)))
                case (.some, .some):
                    preconditionFailure()
                }
            }
        }
    }

    public final class MatchKernel: JETKernel {
        public static let functionName = "compare_xy_simd"
        
        public let computePipeline: ComputePipeline
        
        public init(_ pipeline: ComputePipeline) {
            self.computePipeline = pipeline
        }
        
        @usableFromInline
        func height() -> Int {
            JET.SimdHeight(self.pipeline)
        }
    }
    
    public final class HashKernel: JETKernel {
        public static let functionName = "hash_all"
        
        public let computePipeline: JET.ComputePipeline
        
        public init(_ pipeline: ComputePipeline) {
            self.computePipeline = pipeline
        }
    }
}

// MARK: MTLBuffer.write(_:) filters [UInt32]
extension MTLBuffer {
    @discardableResult
    func write(_ filters: [UInt32]) -> MTLBuffer {
        guard filters.count <= JET.FilterCountCapacity
        else { preconditionFailure("buffer overflow") }
        
        let pointer = self.contents().assumingMemoryBound(to: UInt32.self)
        filters.enumerated().forEach { index, element in
            pointer[index] = element
        }
        
        return self
    }
}

// MARK: MTLBuffer extend
extension Array where Element: FixedWidthInteger {
    @usableFromInline
    func extend(to width: Int, opcodeCount: Int) -> [Element] {
        let difference = width - self.count
        let endIndex = Swift.max(difference - 1, 0)
        let zeroes: [Element] = (0..<endIndex).map { _ in .zero }
        
        return self + zeroes + [ Element(opcodeCount) ]

    }
}

@discardableResult @usableFromInline
func moduloExtend<C: RangeReplaceableCollection, R>(_ data: inout C, modulo: Int, with element: R? = nil) -> Int
where C.Element: BinaryInteger, R == C.Element {
    moduloExtend(&data, modulo: modulo, with: element ?? .zero)
}

@discardableResult @usableFromInline
func moduloExtend<C: RangeReplaceableCollection, R>(_ data: inout C, modulo: Int, with element: R) -> Int
where C.Element == R {
    let (quotient, remainder) = data.count.quotientAndRemainder(dividingBy: modulo)
    let difference = remainder > 0 ? modulo - remainder : 0
    (0..<difference).forEach { _ in
        data.append(element)
    }
    
    return (remainder > 0 ? quotient + 1 : quotient)
}

// MARK: Action, QueueItem, WorkItem
extension JET {
    public enum Action {
        case asynch
        case execute
        case started([JETKernel])
        case await(result: Bool)
        case `continue`
        case stop(with: JET.Error)
    }

    @usableFromInline
    struct QueueItem {
        let filters: [UInt32]
        let key: [UInt8]
        let f: UInt64
        let callback: (Result<JET.Action, JET.Error>) -> Void
    }
}

// MARK: States
extension JET {
    @usableFromInline
    struct PreinitState {
        let device: MTLDeviceStates
        
        init() throws {
            guard let metalDevice = MTLCreateSystemDefaultDevice()
            else { throw JET.Error.metalError("Error: nil result calling MTLCreateSystemDefaultDevice()") }
            
            let library: MTLLibrary
            #if canImport(fltrJET)
            do {
                library = try metalDevice.makeDefaultLibrary(bundle: Bundle.module)
            } catch {
                throw JET.Error.metalError("Error in device.makeDefaultLibrary: \(error)")
            }
            #else
            guard let _library = metalDevice.makeDefaultLibrary()
            else { throw JET.Error.metalError("Error: nil result calling device.makeDefaultLibrary()") }
            library = _library
            #endif

            guard let commandQueue = metalDevice.makeCommandQueue()
            else { throw JET.Error.metalError("Error: nil result calling device.makeCommandQueue()") }
            
            self.device = .init(device: metalDevice, library: library, commandQueue: commandQueue)
        }
    }
    
    @usableFromInline
    struct IdleState {
        let device: MTLDeviceStates
        let kernels: [JETKernel]
        let buffer: DoubleBuffer
        let output: MTLBuffer
        
        init(_ preinitState: PreinitState, kernels: [JETKernel]) throws {
            let device = preinitState.device
            
            guard let output = device.device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
            else { throw JET.Error.metalError("Error: nil result calling device.makeBuffer(length:options:)") }
            
            self.device = device
            self.kernels = kernels
            self.buffer = try .makeBuffers(using: device.device)
            self.output = output
        }
        
        init(_ busyState: BusyState) {
            self.device = busyState.device
            self.kernels = busyState.kernels
            self.buffer = busyState.buffer
            self.output = busyState.output
        }
    }
    
    @usableFromInline
    struct BusyState {
        let device: MTLDeviceStates
        let kernels: [JETKernel]
        let buffer: DoubleBuffer
        let output: MTLBuffer

        init (_ idleState: IdleState) {
            self.device = idleState.device
            self.kernels = idleState.kernels
            self.buffer = idleState.buffer
            self.output = idleState.output
        }
    }
    
    @usableFromInline
    struct StopState {
        let device: MTLDeviceStates
        
        init(device: MTLDeviceStates) {
            self.device = device
        }
    }
}

// MARK: Error
extension JET {
    public enum Error: Swift.Error {
        case illegalState(state: String, event: StaticString)
        case internalError
        case kernelsEmpty
        case makeComputePipeline(wrapped: Swift.Error?)
        case metalError(String)
        case stop
        
        static func illegalState(_ state: JET.StateMachine, function: StaticString = #function) -> Self {
            return .illegalState(state: String(describing: state), event: function)
        }
    }
}

extension JET {
    static func log(function: StaticString = #function,
             file: StaticString = #fileID,
             line: Int = #line) -> (MTLCommandBuffer) -> JET.Error? {
        { commandBuffer in
            var errorEncountered: JET.Error? = nil
            
            if let error = commandBuffer.error as NSError?,
               let errorInfos = error.userInfo[MTLCommandBufferEncoderInfoErrorKey] as? [MTLCommandBufferEncoderInfo] {
                errorInfos.forEach {
                    logger.error("FltrJet [\(function)||\(file):\(line)] "
                                 + "- ErrorINFO[label:\($0.label)][signposts:\($0.debugSignposts.joined(separator: ", "))] "
                                 + "\($0.errorState == .faulted ? "[❌FAULTED]]" : "")")
                }
                errorEncountered = .metalError("commandBuffer.error set")
            }
            commandBuffer.logs.forEach { log in
                let encoderLabel = log.encoderLabel ?? "unknown label"
                logger.error("FltrJet [\(function)||\(file):\(line)]", "- Faulting encoder:", encoderLabel)
                guard let debugLocation = log.debugLocation,
                      let functionName = debugLocation.functionName
                else {
                    return
                }
                logger.error("FltrJet [\(function)||\(file):\(line)]",
                             "- Faulting function [\(functionName):\(debugLocation.line):\(debugLocation.column)]")
                errorEncountered = .metalError("commandBuffer.logs set")
            }
            
            return errorEncountered
        }
    }
}

// MARK: Debug Description
extension JET.StateMachine.StateEnum: CustomDebugStringConvertible {
    public var debugDescription: String {
        var result = [ "StateEnum" ]
        switch self {
        case .busy(let state):
            result.append(".busy(buffer[\(state.buffer)] ")
            result.append("Output[length:\(state.output.length)]")
        case .idle(let state):
            result.append(".idle(buffer[\(state.buffer)] Output[length:\(state.output.length)])")
        case .preinit:
            result.append(".preinit")
        case .stop:
            result.append(".stop")
        }

        return result.joined()
    }
}

extension JET.DoubleBuffer: CustomDebugStringConvertible {
    @usableFromInline
    var debugDescription: String {
        var result = [ "DoubleBuffer(callbacks[#\(self.callbacks.count)] " ]
        result.append("isIdle[\(self.idle())] isFull[\(self.full())] ")
        result.append("hasEncodedCommand[\(self.encodedCommand == nil ? String(false) : String(true))])")
        
        return result.joined()
    }
}

extension JET.StateMachine: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "JET.StateMachine(state: \(String(reflecting: self.state)) queue#: \(self.queue.count) updateRequested: \(self.updateOpcodes != nil) "
            + "opcodeBuffer#: \(self.opcodeBuffer == nil ? "empty" : "\(self.opcodeBuffer!.count)"))"
    }
}

#if DEBUG
public extension JETMatcher {
    var testIsBuffered: Bool {
        let stateMachine = self.lock.withLock {
            self.stateMachine
        }
        
        return stateMachine.opcodeBuffer != nil
    }
    
    var testBufferedCount: Int {
        let stateMachine = self.lock.withLock {
            self.stateMachine
        }
        
        return stateMachine.opcodeBuffer?.mtlSize.width ?? -1
    }
    
    var testIsUpdateRequested: Bool {
        let stateMachine = self.lock.withLock {
            self.stateMachine
        }
        
        return stateMachine.updateOpcodes != nil
    }
}
#endif

