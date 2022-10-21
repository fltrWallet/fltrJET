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
#include "../CfltrJET/CfltrJET.h"
#include "Fastrange.metal"
#include "Filter.metal"
#include "SipHash.metal"
#include <metal_stdlib>
#include <metal_atomic>
#include <metal_simdgroup>
#include <metal_compute>
#include <metal_uniform>

using namespace metal;

inline uint hash0(device const OpCodesStruct &opcode,
                  constant const HashKey &key) {
    device const uchar *hashData = opcode.data;
    thread short length = opcode.count;
    
    thread uint64_t sipHashResult = 0;
    siphash(hashData, length, key.data, sipHashResult);
    
    return mulhi32(key.f, sipHashResult);
}

#define GROUP_X 8
#define GROUP_MAX() (GROUP_X * 32)

kernel void hash_all(device   const OpCodesStruct *opcodes [[ buffer(0) ]],
                     device   uint  *out                   [[ buffer(1) ]],
                     constant const HashKey &key           [[ buffer(2) ]],
                              ushort gid                   [[ thread_position_in_grid ]]) {
    out[gid] = hash0(opcodes[gid], key);
}

kernel void compare_xy_simd(device       uint        *hashes  [[ buffer(0) ]],
                            device const uint        *filters [[ buffer(1) ]],
                            device       atomic_uint *out     [[ buffer(2) ]],
                                         ushort2     gid      [[ thread_position_in_grid ]],
                                         ushort      tid1     [[ thread_index_in_threadgroup ]]) {
    ushort compare_xy = hashes[gid.x] == filters[gid.y];
    threadgroup uint result[1];
    result[0] = simd_or(compare_xy);
    simdgroup_barrier(mem_flags::mem_threadgroup);

    if (tid1 == 0) {
        atomic_fetch_add_explicit(out, result[0], memory_order_relaxed);
    }
}

kernel void hash(device const OpCodesStruct *data [[ buffer(0) ]],
                 constant const HashKey &key [[ buffer(1) ]],
                 device uint64_t *out [[ buffer(2) ]],
                 ushort tid [[ thread_index_in_threadgroup ]],
                 ushort bid [[ threadgroup_position_in_grid ]],
                 ushort blockDim [[ threads_per_threadgroup ]]) {
    ushort i = bid * blockDim + tid;

    thread short length = data[i].count;
    device const uchar *hashData = data[i].data;

    thread uint64_t result;
    siphash(hashData, length, key.data, result);
    
    thread uint match = mulhi(key.f, result);
    
    out[i] = static_cast<uint64_t>(match);
}
