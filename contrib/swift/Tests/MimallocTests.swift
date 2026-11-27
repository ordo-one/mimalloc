// Root suite and what every suite shares.

import Cmimalloc
import Foundation
import MimallocTestSupport
import Testing

// Serialized, and so are the suites nested in it: the mimalloc error handler and the system allocator growth checked
// in Helpers/AllocationChecks.swift are process-wide.
@Suite(.serialized) struct MimallocTests {}

/// Whether `pointer` is in mimalloc's heap exactly when mimalloc replaces malloc, as anything from malloc's family
/// must be.
func inExpectedHeap(_ pointer: UnsafeRawPointer?) -> Bool {
    mi_is_in_heap_region(pointer) == mimallocReplacesMalloc
}

// Small (up to 10 KiB) and medium (up to 80 KiB) blocks, then a large one (up to 512 KiB) and a huge one beyond
// mimalloc's largest size class (include/mimalloc/config.h). Threaded tests use the first three in bulk.
let blockSizesBelowHuge = [16, 1000, 30_000]
let hugeBlockSize = 5_000_000
let blockSizes = blockSizesBelowHuge + [200_000, hugeBlockSize]

/// Looks up a C function that exists on some platforms only, resolved as a C library linked into the binary would.
func libcFunction<T>(_ name: String, as type: T.Type) -> T? {
    dlsym(dlopen(nil, RTLD_NOW), name).map { unsafeBitCast($0, to: type) }
}
