// The Swift counterpart of test/main-override.c. Covers what `swift test` cannot: a real executable (macOS loads tests
// as a bundle) and the static Linux SDK (no Testing).

import Cmimalloc

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

final class Box {}

// musl always overrides; sanitizers never do (contrib/swift/mimalloc.c).
#if Override || canImport(Musl)
    let process = dlopen(nil, RTLD_NOW)
    let expected = dlsym(process, "__asan_init") == nil && dlsym(process, "__tsan_init") == nil
#else
    let expected = false
#endif

let box = Box()
let block = malloc(100)!
let mismatches = [
    ("malloc", mi_is_in_heap_region(block)),
    ("Swift object", mi_is_in_heap_region(Unmanaged.passUnretained(box).toOpaque())),
].filter { $0.1 != expected }.map(\.0)
free(block)
withExtendedLifetime(box) {}

if !mismatches.isEmpty {
    print("expected mi_is_in_heap_region == \(expected): \(mismatches)")
    exit(1)
}

// Freeing across the two APIs only works when they are one allocator.
if expected {
    free(mi_malloc(32))
    mi_free(malloc(32))
}
print("ok, override: \(expected)")
