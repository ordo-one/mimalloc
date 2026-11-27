// Boundary inputs: zero sizes, impossible sizes and alignments, and libc names that exist on some platforms only.

import Foundation
import MimallocTestSupport
import Testing

/// Grows a filled 16-byte block with `resize` and expects the 16 bytes to survive.
private func grownKeepingContents(_ resize: (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?) throws
    -> UnsafeMutableRawPointer
{
    let block = try #require(malloc(16))
    fill(block, count: 16, seed: 16)
    let grown = try #require(resize(block))
    #expect(holdsFill(grown, count: 16, seed: 16))
    return grown
}

extension MimallocTests {
    @Suite struct EdgeCases {
        @Test func zeroSizeRequests() {
            let blocks = [malloc(0), malloc(0), calloc(0, 8)]
            #expect(blocks.allSatisfy { $0 != nil && inExpectedHeap($0) })
            #expect(Set(blocks.map { Int(bitPattern: $0) }).count == blocks.count)
            blocks.forEach { free($0) }
            free(nil)
            for alignment in [1, 4096] {
                let block = UnsafeMutableRawPointer.allocate(byteCount: 0, alignment: alignment)
                #expect(inExpectedHeap(block) && Int(bitPattern: block) % alignment == 0)
                block.deallocate()
            }
        }

        @Test(.enabled(if: mimallocReplacesMalloc)) func invalidRequestsFailAndKeepTheBlock() throws {
            let block = try #require(malloc(16))
            defer { free(block) }
            fill(block, count: 16, seed: 16)
            let tooLarge: [() -> UnsafeMutableRawPointer?] = [
                { malloc(.max) },
                { calloc(.max, 3) },  // count times size overflows size_t
                { realloc(block, .max) },
            ]
            for allocate in tooLarge {
                errno = 0
                let result = allocate()
                let error = errno  // read before #expect can call into libc
                #expect(result == nil && error == ENOMEM)
            }
            #expect(aligned_alloc(3, 16) == nil)  // alignment not a power of two
            var aligned: UnsafeMutableRawPointer?
            #expect(posix_memalign(&aligned, 3, 16) == EINVAL)
            #expect(holdsFill(block, count: 16, seed: 16))  // the failed realloc left the block intact
        }

        @Test func rarelyUsedLibcFunctions() throws {
            typealias Allocate = @convention(c) (Int) -> UnsafeMutableRawPointer?
            typealias AllocateAligned = @convention(c) (Int, Int) -> UnsafeMutableRawPointer?
            typealias Resize = @convention(c) (UnsafeMutableRawPointer?, Int) -> UnsafeMutableRawPointer?
            typealias ResizeArray = @convention(c) (UnsafeMutableRawPointer?, Int, Int) -> UnsafeMutableRawPointer?
            typealias FreeSized = @convention(c) (UnsafeMutableRawPointer?, Int) -> Void

            var blocks: [UnsafeMutableRawPointer] = []
            if let memalign = libcFunction("memalign", as: AllocateAligned.self) {
                let block = try #require(memalign(256, 100))
                #expect(Int(bitPattern: block) % 256 == 0)
                blocks.append(block)
            }
            if let pvalloc = libcFunction("pvalloc", as: Allocate.self) {
                blocks.append(try #require(pvalloc(100)))
            }
            if let reallocf = libcFunction("reallocf", as: Resize.self) {
                blocks.append(try grownKeepingContents { reallocf($0, 5000) })
            }
            if let reallocarray = libcFunction("reallocarray", as: ResizeArray.self) {
                blocks.append(try grownKeepingContents { reallocarray($0, 100, 50) })
            }
            #expect(!blocks.isEmpty)
            for block in blocks {
                #expect(inExpectedHeap(block))
                free(block)
            }
            if let freeSized = libcFunction("free_sized", as: FreeSized.self) { freeSized(malloc(100), 100) }
        }
    }
}
