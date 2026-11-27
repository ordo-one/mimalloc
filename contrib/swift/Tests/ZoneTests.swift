// macOS only: other images (CoreFoundation, libc++) allocate through the default malloc zone, not through this
// binary's symbols, so mimalloc must serve and describe blocks through that zone too.

import Cmimalloc
import Foundation
import MimallocTestSupport
import Testing

#if canImport(Darwin)
    import Darwin

    extension MimallocTests {
        @Suite(.enabled(if: mimallocReplacesMalloc)) struct Zone {
            @Test func defaultZoneServesSystemLibraries() throws {
                let zone = try #require(malloc_default_zone())
                let block = try #require(malloc_zone_malloc(zone, 16))
                fill(block, count: 16, seed: 16)
                let grown = try #require(malloc_zone_realloc(zone, block, 5000))
                #expect(holdsFill(grown, count: 16, seed: 16))
                #expect(mi_is_in_heap_region(grown))
                malloc_zone_free(zone, grown)

                let page = try #require(malloc_zone_valloc(zone, 100))
                #expect(mi_is_in_heap_region(page) && Int(bitPattern: page) % Int(getpagesize()) == 0)
                malloc_zone_free(zone, page)

                var batch = [UnsafeMutableRawPointer?](repeating: nil, count: 16)
                let count = Int(malloc_zone_batch_malloc(zone, 64, &batch, 16))
                try #require(count == 16)
                let allocated = batch[..<count].compactMap { $0 }
                #expect(allocated.count == count)
                for (index, block) in allocated.enumerated() { fill(block, count: 64, seed: index) }
                #expect(allocated.enumerated().allSatisfy { index, block in
                    mi_is_in_heap_region(block) && holdsFill(block, count: 64, seed: index)
                })
                malloc_zone_batch_free(zone, &batch, UInt32(count))
            }

            // Instruments, leaks and the memory-pressure handler query the zone of a block rather than allocating.
            @Test func zoneIntrospection() throws {
                let block = try #require(malloc(100))
                defer { free(block) }
                let zone = malloc_zone_from_ptr(block)
                #expect(zone == malloc_default_zone())
                // Through the zone: this binary defines malloc_good_size itself. libmalloc's own sizes match
                // mimalloc's up to 32 KiB (33000 gives 49152 there).
                let goodSize = try #require(zone?.pointee.introspect.pointee.good_size)
                #expect(goodSize(zone, 33_000) == mi_good_size(33_000))
                // Smoke checks only: these must not crash; their results depend on mimalloc's bookkeeping.
                var stats = malloc_statistics_t()
                malloc_zone_statistics(zone, &stats)
                _ = malloc_zone_pressure_relief(zone, 0)
            }
        }
    }
#endif
