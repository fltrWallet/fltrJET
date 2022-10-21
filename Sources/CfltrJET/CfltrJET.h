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
#ifndef INCLUDE_CFLTRJET_H
#define INCLUDE_CFLTRJET_H
#include <simd/simd.h>

#ifndef __cplusplus
uint64_t cSipHash(const uint8_t *in, const size_t inlen, const uint8_t *k);
#endif


typedef struct {
    uint32_t x;
} cfltr;

typedef char cfltr_result;

typedef struct {
    uint16_t count;
    uint16_t data[4096];
} FiltersStruct;

typedef struct {
    uint32_t count;
    uint32_t data[4096];
} FiltersStruct32;


typedef struct {
    uint8_t data[39];
    uint8_t count; // critical for alignment with reference siphash function
} OpCodesStruct;

typedef struct {
    uint8_t data[16];
    uint64_t f;
} HashKey;

typedef struct {
    OpCodesStruct opcodes[3];
} HashStruct;
#endif

