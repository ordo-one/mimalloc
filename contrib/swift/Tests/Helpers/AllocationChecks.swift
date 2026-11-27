// Checks that a test's allocations went to mimalloc and stayed intact: mimalloc's error count, and on macOS growth of
// the system allocator, which catches allocations a test cannot see.

import Cmimalloc
import Foundation
import Synchronization
import Testing

// mimalloc calls the error handler on the thread that hit the error.
private let mimallocErrorCount = Atomic<Int>(0)

/// Expects mimalloc to report no error while `body` runs: invalid requests always, overflows and double frees only in
/// Debug, Secure and ASan builds. The handler is process-wide, so this relies on the serialized suite.
func expectNoMimallocErrors(
    sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> Void
) async rethrows {
    mimallocErrorCount.store(0, ordering: .relaxed)
    mi_register_error({ _, _ in mimallocErrorCount.add(1, ordering: .relaxed) }, nil)
    defer { mi_register_error(nil, nil) }
    try await body()
    let errors = mimallocErrorCount.load(ordering: .relaxed)
    #expect(errors == 0, "mimalloc reported \(errors) errors", sourceLocation: sourceLocation)
}

/// Bytes in use in the Darwin default malloc zones, except the ObjC runtime's `objc-class_rw_t` zone, which never
/// reaches mimalloc. 0 elsewhere: on Linux the override leaves glibc's arenas empty (measured with `malloc_info`).
func systemAllocatorBytesInUse() throws -> Int {
    #if canImport(Darwin)
        var zones: UnsafeMutablePointer<vm_address_t>?
        var count: UInt32 = 0
        malloc_get_all_zones(mach_task_self_, nil, &zones, &count)
        let addresses = UnsafeBufferPointer(start: try #require(zones), count: Int(count))
        let defaultZones = addresses.compactMap { UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt($0)) }
            .filter { zone in malloc_get_zone_name(zone).map { String(cString: $0).hasPrefix("Default") } ?? false }
        try #require(!defaultZones.isEmpty, "no Default malloc zone to measure")
        return defaultZones.reduce(0) { total, zone in
            var stats = malloc_statistics_t()
            malloc_zone_statistics(zone, &stats)
            return total + Int(stats.size_in_use)
        }
    #else
        return 0
    #endif
}

/// Runs `body`, which returns what it allocated, and expects no mimalloc error and, on macOS, no net growth of the
/// system allocator, which frees inside `body` or elsewhere can hide. Only when mimalloc replaces malloc.
func expectAllocatedByMimalloc(
    sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> Any
) async throws {
    try await expectNoMimallocErrors(sourceLocation: sourceLocation) {
        let before = try systemAllocatorBytesInUse()
        let allocated = try await body()
        let growth = try systemAllocatorBytesInUse() - before
        withExtendedLifetime(allocated) {
            // Each test allocates well over 4 KiB on its path, so a bypass exceeds this; other activity stays below.
            #expect(growth < 4096, "system allocator grew by \(growth) bytes", sourceLocation: sourceLocation)
        }
    }
}
