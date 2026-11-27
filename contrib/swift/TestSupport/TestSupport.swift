// What both test targets share: whether mimalloc replaces malloc, and no core file from a child that may crash.

import Foundation

/// True when malloc and free are mimalloc: the Override trait, except under sanitizers (contrib/swift/mimalloc.c).
/// Tests of where malloc's blocks land run only then; otherwise they would test libc.
public let mimallocReplacesMalloc: Bool = {
    #if Override && !os(Windows)
        let process = dlopen(nil, RTLD_NOW)
        return dlsym(process, "__asan_init") == nil && dlsym(process, "__tsan_init") == nil
    #else
        return false
    #endif
}()

/// Stops this process from writing a core file if it crashes; Linux needs limit 1, as 0 still runs a core_pattern pipe.
public func disableCoreDumps() {
    #if canImport(Glibc)
        var limit = rlimit(rlim_cur: 1, rlim_max: 1)
        _ = setrlimit(__rlimit_resource_t(RLIMIT_CORE.rawValue), &limit)
    #elseif canImport(Darwin)
        var limit = rlimit(rlim_cur: 0, rlim_max: 0)
        _ = setrlimit(RLIMIT_CORE, &limit)
    #endif
}
