// Fills blocks with a per-block byte and checks it later, so overlapping or clobbered blocks are caught.

import Foundation

/// Fills `count` bytes of `block` with a byte derived from `seed`: a block that overlaps one with another seed, or
/// loses its contents, fails `holdsFill`. Seeds 255 apart share a byte.
func fill(_ block: UnsafeMutableRawPointer, count: Int, seed: Int) {
    memset(block, Int32(fillByte(seed)), count)
}

func holdsFill(_ block: UnsafeRawPointer, count: Int, seed: Int) -> Bool {
    // Every byte equals the first when the block equals itself shifted by one; memcmp keeps a 5 MB check fast in debug.
    block.load(as: UInt8.self) == fillByte(seed) && memcmp(block, block + 1, count - 1) == 0
}

// Never 0, so a block mimalloc zeroed or never filled fails too.
private func fillByte(_ seed: Int) -> UInt8 { UInt8(seed % 255 + 1) }
