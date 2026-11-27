/* ----------------------------------------------------------------------------
Copyright (c) 2018-2026, Microsoft Research, Daan Leijen
This is free software; you can redistribute it and/or modify it under the
terms of the MIT license. A copy of the license can be found in the file
"LICENSE" at the root of this distribution.
-----------------------------------------------------------------------------*/

// Builds mimalloc as one translation unit (src/static.c) for the Swift package, mapping the package traits
// (MI_SWIFT_*, set in Package.swift) to mimalloc defines. A define passed through MIMALLOC_DEFINES wins.

// Debug trait: assertions and invariant checks. Otherwise NDEBUG, from which include/mimalloc/decl.h sets MI_DEBUG 0.
#if defined(MI_SWIFT_DEBUG)
  #if !defined(MI_DEBUG)
    #define MI_DEBUG 2
  #endif
#elif !defined(MI_DEBUG) && !defined(NDEBUG)
  #define NDEBUG 1
#endif

// Secure traits unify across the dependency graph, so several can be on at once; the highest level wins.
#if !defined(MI_SECURE)
  #if defined(MI_SWIFT_SECURE)
    #define MI_SECURE 4
  #elif defined(MI_SWIFT_SECURE_CHECKED)
    #define MI_SECURE 2
  #elif defined(MI_SWIFT_SECURE_BASIC)
    #define MI_SECURE 1
  #endif
#endif

// MTE and PAC traits on arm64 only: include/mimalloc/arch.h rejects them elsewhere, e.g. in a universal build's x86_64
// slice.
#if defined(__aarch64__) || defined(__arm64__)
  #if defined(MI_SWIFT_MTE) && !defined(MI_MTE)
    #define MI_MTE 2
  #endif
  #if defined(MI_SWIFT_PAC) && !defined(MI_PAC)
    #define MI_PAC 2
  #endif
#endif

// mimalloc needs MI_LIBC_MUSL on musl (Swift static Linux SDK); <limits.h> defines __GLIBC__ only on glibc.
// _DEFAULT_SOURCE must precede that first system header, or glibc fixes its feature set without it.
#if defined(__linux__) && !defined(__ANDROID__)
  #if !defined(_DEFAULT_SOURCE)
    #define _DEFAULT_SOURCE
  #endif
  #include <limits.h>
  #if !defined(__GLIBC__) && !defined(MI_LIBC_MUSL)
    #define MI_LIBC_MUSL 1
  #endif
#endif

// Sanitizers (swift build --sanitize=...) replace malloc themselves to track every allocation, so the override
// is skipped; mimalloc's own heap is annotated for them instead, as CMake's MI_TRACK=ASAN and MI_DEBUG_TSAN=ON do.
#if defined(__has_feature)
  #if __has_feature(address_sanitizer)
    #define MI_SWIFT_SANITIZER 1
    #if !defined(MI_TRACK_ASAN)
      #define MI_TRACK_ASAN 1
    #endif
  #endif
  #if __has_feature(thread_sanitizer)
    #define MI_SWIFT_SANITIZER 1
    #if !defined(MI_TSAN)
      #define MI_TSAN 1
    #endif
  #endif
#endif

// The static Linux SDK's musl allocates with its own mimalloc, which links in beside this one (duplicate mi_*
// symbols) unless this one defines malloc, so musl always overrides.
#if defined(MI_LIBC_MUSL) && !defined(MI_SWIFT_SANITIZER) && !defined(MI_SWIFT_OVERRIDE)
  #define MI_SWIFT_OVERRIDE 1
#endif

// Override trait: on Linux the executable exports malloc, free and friends in place of libc's; on Apple platforms
// mimalloc replaces the default malloc zone. Windows needs the mimalloc-redirect DLL, which a static build cannot do.
#if defined(MI_SWIFT_OVERRIDE) && !defined(MI_SWIFT_SANITIZER) && !defined(_WIN32)
  #if !defined(MI_MALLOC_OVERRIDE)
    #define MI_MALLOC_OVERRIDE 1
  #endif
  #if defined(__APPLE__) && !defined(MI_OSX_ZONE)
    #define MI_OSX_ZONE 1
  #endif
#endif

// -fvisibility=hidden also hides the mi_* API, which mimalloc.h exports only in a shared-library build, and swiftbuild
// prelinking then makes it local. Include mimalloc.h once as a shared build, then restore the defines for src/static.c.
#if !defined(_WIN32)
  #pragma push_macro("MI_SHARED_LIB")
  #pragma push_macro("MI_SHARED_LIB_EXPORT")
  #undef MI_SHARED_LIB
  #undef MI_SHARED_LIB_EXPORT
  #define MI_SHARED_LIB 1
  #define MI_SHARED_LIB_EXPORT 1
  #include "../../include/mimalloc.h"
  #pragma pop_macro("MI_SHARED_LIB")
  #pragma pop_macro("MI_SHARED_LIB_EXPORT")
#endif

#include "../../src/static.c"
