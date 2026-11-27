// Blocks freed on another thread or task than the one that allocated them, also after that thread has exited or in a
// forked child. Every block is filled when allocated and must still hold its fill when freed.

import Cmimalloc
import Foundation
import MimallocTestSupport
import Synchronization
import Testing

nonisolated(unsafe) private var exitKey = pthread_key_t()
private let destructorRuns = Atomic<Int>(0)

/// Allocates and frees one block; whether it came from mimalloc. Safe in a forked child: no Swift allocation.
private func mallocsFromMimalloc(_ size: Int) -> Bool {
    let block = malloc(size)
    defer { free(block) }
    return block != nil && mi_is_in_heap_region(block)
}

/// A block filled with its seed's byte, held as an address so it can move between threads.
private struct Block: Sendable {
    let address: Int
    let size: Int
    let seed: Int

    // malloc reaches mimalloc only through Override; without it, and under sanitizers, use mimalloc directly.
    init?(size: Int, seed: Int) {
        guard let pointer = mimallocReplacesMalloc ? malloc(size) : mi_malloc(size) else { return nil }
        fill(pointer, count: size, seed: seed)
        (address, self.size, self.seed) = (Int(bitPattern: pointer), size, seed)
    }

    /// Frees the block; false when it was outside mimalloc or no longer held its fill.
    func release() -> Bool {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return false }
        let intact = mi_is_in_heap_region(pointer) && holdsFill(pointer, count: size, seed: seed)
        mimallocReplacesMalloc ? free(pointer) : mi_free(pointer)
        return intact
    }
}

/// Frees each block and counts those that failed to allocate, were outside mimalloc, or lost their fill.
private func releaseCountingDamaged<Blocks: Sequence<Block?>>(_ blocks: Blocks) -> Int {
    blocks.reduce(0) { damaged, block in damaged + (block?.release() == true ? 0 : 1) }
}

extension MimallocTests {
    @Suite struct Threads {
        // A free on another thread than the allocation takes mimalloc's remote-free path.
        @Test func crossThreadFree() async {
            let blocks = (0..<64).map { Block(size: 64 + $0, seed: $0) }
            await expectNoMimallocErrors {
                #expect(onNewThreads(1) { _ in releaseCountingDamaged(blocks) } == [0])
            }
        }

        // Blocks that outlive their thread sit in pages mimalloc abandons at thread exit; freeing them later reclaims
        // those pages.
        @Test func freeAfterThreadExit() async {
            await expectNoMimallocErrors {
                let results = onNewThreads(200) { thread in
                    // Large and huge blocks on 2 threads only: every block is filled, and on all 200 threads the
                    // survivors alone would hold about 8 GB.
                    let sizes = thread < 2 ? blockSizes : blockSizesBelowHuge
                    let blocks = (0..<64).map { index in
                        Block(size: sizes[(index + thread) % sizes.count], seed: thread * 64 + index)
                    }
                    return (damaged: releaseCountingDamaged(blocks[..<32]), survivors: blocks[32...])
                }
                #expect(results.map(\.damaged).reduce(0, +) == 0)
                #expect(releaseCountingDamaged(results.flatMap(\.survivors)) == 0)
            }
        }

        // Foundation, libdispatch and Swift thread-locals allocate and free in pthread key destructors, in any order
        // with mimalloc's thread-exit cleanup; a run counts only if its block was intact and its new one from mimalloc.
        @Test(.enabled(if: mimallocReplacesMalloc)) func allocateAndFreeInThreadExitDestructors() async {
            destructorRuns.store(0, ordering: .relaxed)
            #expect(pthread_key_create(&exitKey) { block in
                let block: UnsafeMutableRawPointer? = block  // non-optional on Darwin, optional on Glibc
                let intact = block.map { holdsFill($0, count: 100_000, seed: 7) } ?? false
                free(block)
                let fresh = malloc(1000)
                if intact && fresh != nil && inExpectedHeap(fresh) { destructorRuns.add(1, ordering: .relaxed) }
                free(fresh)
            } == 0)
            defer { pthread_key_delete(exitKey) }
            await expectNoMimallocErrors {
                let installed = onNewThreads(50) { _ in
                    Thread.current.threadDictionary["block"] = NSMutableData(length: 100_000)
                    guard let block = malloc(100_000) else { return false }
                    fill(block, count: 100_000, seed: 7)
                    return pthread_setspecific(exitKey, block) == 0
                }
                #expect(installed == Array(repeating: true, count: 50))
            }
            #expect(destructorRuns.load(ordering: .relaxed) == 50)
        }

        // A forked child has only the forking thread: mimalloc's fork handler (src/heap/subproc.c, the zone's
        // reinit_lock on macOS) drops dead threads' state, and the child must still free inherited blocks and allocate.
        @Test(.enabled(if: mimallocReplacesMalloc)) func allocateAndFreeInForkedChild() throws {
            let inherited = try #require(malloc(1000))
            fill(inherited, count: 1000, seed: 3)
            defer { free(inherited) }
            // The macOS SDK hides fork from Swift (a compile error), so look it up; C code linked in can still fork.
            let fork = try #require(libcFunction("fork", as: (@convention(c) () -> pid_t).self))
            let pid = fork()
            if pid == 0 {
                // No Swift allocation or runtime lock here: a thread that held one at the fork is gone in the child.
                disableCoreDumps()
                let intact = holdsFill(inherited, count: 1000, seed: 3)
                free(inherited)
                let allocated = mallocsFromMimalloc(16) && mallocsFromMimalloc(1000) && mallocsFromMimalloc(30_000)
                    && mallocsFromMimalloc(200_000) && mallocsFromMimalloc(5_000_000)
                _exit(intact && allocated ? 0 : 1)
            }
            try #require(pid > 0)
            var status: Int32 = -1
            var waited: pid_t = 0
            for _ in 0..<1000 where waited == 0 {  // 10 s
                waited = waitpid(pid, &status, WNOHANG)
                if waited == 0 { usleep(10_000) }
            }
            if waited == 0 {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
            }
            #expect(waited == pid, "child did not exit within 10 s")
            #expect(status == 0, "child exit status \(status)")
        }

        // A task can resume on another pool thread after each suspension, so its free may not run where it allocated.
        @Test func freeAcrossTaskSuspension() async {
            await expectNoMimallocErrors {
                let damaged = await withTaskGroup(of: Int.self) { group in
                    for task in 0..<1000 {
                        group.addTask {
                            // Huge blocks in 4 tasks only: all 1000 tasks can be suspended at once.
                            let size = task < 4 ? hugeBlockSize : blockSizesBelowHuge[task % blockSizesBelowHuge.count]
                            let block = Block(size: size, seed: task)
                            await Task.yield()
                            return releaseCountingDamaged([block])
                        }
                    }
                    return await group.reduce(0, +)
                }
                #expect(damaged == 0)
            }
        }
    }
}
