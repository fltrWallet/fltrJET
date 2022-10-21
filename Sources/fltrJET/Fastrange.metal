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
#ifndef Fastrange_hpp
#define Fastrange_hpp
#import <metal_integer>

inline uint fastrange(uint64_t x,
                      uint64_t y) {
    uint64_t a = x >> 32;
    uint64_t b = x & 0xffffffff;
    uint64_t c = y >> 32;
    uint64_t d = y & 0xffffffff;

    uint64_t ac = a * c;
    uint64_t bc = b * c;
    uint64_t ad = a * d;
    uint64_t bd = b * d;

    uint64_t mid34 = (bd >> 32) + (bc & 0xffffffff) + (ad & 0xffffffff);
    uint64_t upper64 = ac + (bc >> 32) + (ad >> 32) + (mid34 >> 32);
    return static_cast<uint>(upper64);

    //  uint64_t lower64 = (mid34 << 32) | (bd & 0xffffffff);
}

inline uint mulhi32(uint64_t x, uint64_t y) {
    return static_cast<uint>(metal::mulhi(x, y));
}

#endif
