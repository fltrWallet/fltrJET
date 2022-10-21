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
#ifndef Filter_hpp
#define Filter_hpp

inline void filter32(device const uint &opcode,
                     device const uint *filters,
                     device const short &filtersCount,
                     device bool &out) {
    thread bool result = false;
    for (short index = short(0); index < filtersCount; ++index) {
        result |= filters[index] == opcode;
    }
    
    out = result;
}

inline void filter64(device const uint64_t &opcode,
                     device const uint64_t *filters,
                     device const short &filtersCount,
                     device bool &out) {
    thread bool result = false;
    for (short index = short(0); index < filtersCount; ++index) {
        result |= filters[index] == opcode;
    }
    
    out = result;
}

#endif
