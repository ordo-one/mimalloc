// Swift counterpart of test/test-stress.c: threads allocate Swift objects of random sizes, pass them through shared
// slots, and exit while some objects survive into the next generation of threads, which frees them.

import Foundation
import MimallocTestSupport
import Synchronization
import Testing

/// A tail-allocated object filled with test-stress.c's pattern: one Swift allocation per item, as with its calloc.
private final class Item: ManagedBuffer<Int, UInt> {
    static let cookie: UInt = 0xbf58_476d_1ce4_e5b9

    static func make(count: Int) -> Item {
        let item = unsafeDowncast(create(minimumCapacity: count) { _ in count }, to: Item.self)
        item.withUnsafeMutablePointerToElements { words in
            for index in 0..<count { (words + index).initialize(to: UInt(count - index) ^ cookie) }
        }
        return item
    }

    /// In mimalloc and still holding the pattern it was filled with; a clobbered count fails too.
    var intact: Bool {
        withUnsafeMutablePointers { count, words in
            let count = count.pointee
            return inExpectedHeap(Unmanaged.passUnretained(self).toOpaque()) && count > 0 && count <= capacity
                && (0..<count).allSatisfy { words[$0] ^ Item.cookie == UInt(count - $0) }
        }
    }
}

/// A slot items move through between threads; exchanging hands the item, and its last release, to the caller.
private final class Slot: Sendable {
    private let item = Atomic<Int>(0)  // a retained Item's address, or 0

    func exchange(_ new: Item?) -> Item? {
        let address = new.map { Int(bitPattern: Unmanaged.passRetained($0).toOpaque()) } ?? 0
        let old = item.exchange(address, ordering: .acquiringAndReleasing)
        return UnsafeRawPointer(bitPattern: old).map { Unmanaged<Item>.fromOpaque($0).takeRetainedValue() }
    }
}

/// test-stress.c's splitmix64 `pick`.
private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        var x = state
        x ^= x >> 30
        x &*= 0xbf58_476d_1ce4_e5b9
        x ^= x >> 27
        x &*= 0x94d0_49bb_1331_11eb
        x ^= x >> 31
        state = x
        return x
    }

    mutating func pick(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func chance(_ percent: Int) -> Bool { pick(100) <= percent }  // as test-stress.c: percent + 1 in 100
}

private func damaged(_ item: Item?) -> Int {
    item.map { $0.intact ? 0 : 1 } ?? 0
}

/// One thread of test-stress.c's `stress`; returns how many released items were damaged.
private func stress(thread: Int, scale: Int, slots: [Slot]) -> Int {
    var random = SplitMix64(state: UInt64(thread + 1) * 43)
    func allocate(maxShift: Int) -> Item {
        let count = 1 << random.pick(maxShift)
        return Item.make(count: random.chance(1) ? count * 100 : count)  // about 2% large
    }
    var allocations = 100 * scale * (thread % 8 + 1)  // some threads do more
    var retain = allocations / 2
    var data: [Item?] = []
    var retained: [Item] = []
    var result = 0
    while allocations > 0 || retain > 0 {
        if retain == 0 || (random.chance(50) && allocations > 0) {
            allocations -= 1
            data.append(allocate(maxShift: 5))
        } else {
            retained.append(allocate(maxShift: 7))
            retain -= 1
        }
        if random.chance(66), !data.isEmpty {
            let index = random.pick(data.count)
            result += damaged(data[index])
            data[index] = nil
        }
        if random.chance(25), !data.isEmpty {
            let index = random.pick(data.count)
            data[index] = slots[random.pick(slots.count)].exchange(data[index])
        }
    }
    return result + retained.reduce(0) { $0 + damaged($1) } + data.reduce(0) { $0 + damaged($1) }
}

extension MimallocTests {
    @Suite struct Stress {
        // Lighter than test-stress.c's 32 threads, scale 50 and 50 iterations, to stay near a second in debug builds.
        @Test(.enabled(if: mimallocReplacesMalloc))
        func objectsAcrossThreadGenerations() async {
            let slots = (0..<1000).map { _ in Slot() }
            var random = SplitMix64(state: 0x7feb_352d)
            let iterations = 10
            await expectNoMimallocErrors {
                var result = 0
                for iteration in 0..<iterations {
                    result += onNewThreads(8) { stress(thread: $0, scale: 5, slots: slots) }.reduce(0, +)
                    // Half the slots survive into the next generation of threads, all after the last.
                    for slot in slots where random.chance(50) || iteration == iterations - 1 {
                        result += damaged(slot.exchange(nil))
                    }
                }
                #expect(result == 0)
            }
        }
    }
}
