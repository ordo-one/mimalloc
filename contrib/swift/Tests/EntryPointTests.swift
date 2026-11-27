// The C allocation functions Swift and C code call by name (malloc, calloc, realloc, posix_memalign, ...) land in
// mimalloc when it overrides malloc, keep their contents and alignment, and report the usable size Swift relies on.

import Cmimalloc
import Foundation
import MimallocTestSupport
import Testing

extension MimallocTests {
    @Suite struct EntryPoints {
        // C code in the process reallocs: contents survive each size-class change, and growth within the usable size
        // stays in place.
        @Test func reallocKeepsContents() throws {
            var block = try #require(malloc(17))  // usable size 24 in the 24-byte bin, unless padding is on
            var size = 17
            fill(block, count: size, seed: size)
            if mimallocReplacesMalloc {
                let grown = try #require(realloc(block, mi_usable_size(block)))
                #expect(grown == block)
                block = grown
            }
            for newSize in blockSizes.dropFirst() + [1000, 16] {
                block = try #require(realloc(block, newSize))
                #expect(holdsFill(block, count: min(size, newSize), seed: size))
                #expect(inExpectedHeap(block))
                size = newSize
                fill(block, count: size, seed: size)
            }
            free(block)
        }

        enum AllocationFunction: CaseIterable {
            case viaMalloc, viaCalloc, viaPosixMemalign, viaAlignedAlloc, viaValloc, viaStrdup

            func allocate() -> (block: UnsafeMutableRawPointer?, size: Int, alignment: Int) {
                switch self {
                case .viaMalloc:
                    return (malloc(100), 100, MemoryLayout<Int>.alignment)
                case .viaCalloc:
                    return (calloc(25, 4), 100, MemoryLayout<Int>.alignment)
                case .viaPosixMemalign:
                    var block: UnsafeMutableRawPointer?
                    return (posix_memalign(&block, 256, 1000) == 0 ? block : nil, 1000, 256)
                case .viaAlignedAlloc:
                    return (aligned_alloc(4096, 8192), 8192, 4096)
                case .viaValloc:
                    return (valloc(100), 100, Int(getpagesize()))
                case .viaStrdup:
                    return (UnsafeMutableRawPointer(strdup("mimalloc")), 9, 1)
                }
            }
        }

        // Each lands where malloc does, aligned as asked, with its initial contents, malloc_size covering the request,
        // and every requested byte writable.
        @Test(arguments: AllocationFunction.allCases)
        func allocationFunctions(_ function: AllocationFunction) throws {
            let (allocated, size, alignment) = function.allocate()
            let block = try #require(allocated)
            defer { free(block) }
            #expect(inExpectedHeap(block))
            #expect(Int(bitPattern: block) % alignment == 0)
            switch function {
            case .viaCalloc: #expect(UnsafeRawBufferPointer(start: block, count: size).allSatisfy { $0 == 0 })
            case .viaStrdup: #expect(String(cString: block.assumingMemoryBound(to: CChar.self)) == "mimalloc")
            default: break
            }
            // The Swift runtime sizes Array/String capacity from this, so it must come from the same allocator.
            #if canImport(Glibc)
                // Glibc's Swift module omits malloc.h.
                typealias UsableSize = @convention(c) (UnsafeMutableRawPointer?) -> Int
                let usableSize = try #require(libcFunction("malloc_usable_size", as: UsableSize.self))
                #expect(usableSize(block) >= size)
            #else
                #expect(malloc_size(block) >= size)
            #endif
            fill(block, count: size, seed: size)
            #expect(holdsFill(block, count: size, seed: size))
        }
    }
}
