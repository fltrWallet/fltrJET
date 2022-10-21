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
#ifndef SipHash_hpp
#define SipHash_hpp

#define ROTL(x, b) (uint64_t)(((x) << (b)) | ((x) >> (64 - (b))))

#define SIPROUND                                                               \
    do {                                                                       \
        v0 += v1;                                                              \
        v1 = ROTL(v1, 13);                                                     \
        v1 ^= v0;                                                              \
        v0 = ROTL(v0, 32);                                                     \
        v2 += v3;                                                              \
        v3 = ROTL(v3, 16);                                                     \
        v3 ^= v2;                                                              \
        v0 += v3;                                                              \
        v3 = ROTL(v3, 21);                                                     \
        v3 ^= v0;                                                              \
        v2 += v1;                                                              \
        v1 = ROTL(v1, 17);                                                     \
        v1 ^= v2;                                                              \
        v2 = ROTL(v2, 32);                                                     \
    } while (0)

inline void siphash(device const uint8_t *in,
                    thread const short inlen,
                    constant const uint8_t *k,
//                    constant const metal::uniform<uint8_t> k[16],
                    thread uint64_t &out) {

    uint64_t v0 = 0x736f6d6570736575ULL;
    uint64_t v1 = 0x646f72616e646f6dULL;
    uint64_t v2 = 0x6c7967656e657261ULL;
    uint64_t v3 = 0x7465646279746573ULL;
    
//    metal::uniform<uint64_t> k0 = *reinterpret_cast<constant metal::uniform<uint64_t>*>(k);
//    metal::uniform<uint64_t> k1 = *reinterpret_cast<constant metal::uniform<uint64_t>*>(k + 8);
    
    uint64_t k0 = *reinterpret_cast<constant uint64_t*>(k);
    uint64_t k1 = *reinterpret_cast<constant uint64_t*>(k + 8);
    uint64_t m;
    thread short i;
    device const uint8_t *end = in + (inlen & (0xfff8));
    const short left = inlen & 7;
    thread uint64_t b = ((uint64_t)inlen) << 56;

//    v3 = v3 ^ k1;
//    v2 = v2 ^ k0;
//    v1 = v1 ^ k1;
//    v0 = v0 ^ k0;

    v3 ^= k1;
    v2 ^= k0;
    v1 ^= k1;
    v0 ^= k0;

    for (; in != end; in += 8) {
        m = *reinterpret_cast<device const uint64_t*>(in);
        v3 ^= m;

        for (i = short(0); i < short(2); ++i)
            SIPROUND;

        v0 ^= m;
    }

    switch (left) {
    case 7:
        b |= ((uint64_t)in[6]) << 48;
    case 6:
        b |= ((uint64_t)in[5]) << 40;
    case 5:
        b |= ((uint64_t)in[4]) << 32;
    case 4:
        b |= ((uint64_t)in[3]) << 24;
    case 3:
        b |= ((uint64_t)in[2]) << 16;
    case 2:
        b |= ((uint64_t)in[1]) << 8;
    case 1:
        b |= ((uint64_t)in[0]);
        break;
    case 0:
        break;
    }

    v3 ^= b;

    for (i = short(0); i < short(2); ++i)
        SIPROUND;

    v0 ^= b;
    v2 ^= 0xff;

    for (i = short(0); i < short(4); ++i)
        SIPROUND;

    b = v0 ^ v1 ^ v2 ^ v3;
    
    out = b;
}

#endif
