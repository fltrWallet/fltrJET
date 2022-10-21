# ***EXPERIMENTAL***
This code is not used in production. It is experimental in nature and is not production ready.

# fltrJET
fltrJET (Jump Every Time) is an exerimental MetalKit SIMD execution engine for Bitcoin Compact Filter matching for [fltrWallet](https://apps.apple.com/us/app/fltrwallet/id1620857882)

## Idea
Since compact filter matching can be executed in parallel, this package explores the possibility of doing so using the inbuilt GPU of Apple Silicon over MetalKit. It is currently slower than the optimized C/Swift version in production. However, there are a number of possible improvements
- The code can be much better optimized for parallel execution (especially the hashing part)
- It might make sense to execute the filter matching at a more narrow bit-width and progressively expand to the final and necessary 64-bit width
- Batching multiple filters and execute many at once to reduce scheduling overhead

It may prove that it is simply not useful to execute compact filters in a SIMD manner. If you are interested in GPU programming and MetalKit, please let us know so that progress can be made.

## Ackgnowledgements
fltrJET makes use of the fastrange algorithm by Daniel Lemire under Apache 2 license. [SipHash](https://github.com/veorq/SipHash) is ported from C under the CC0 1.0 Universal license.
