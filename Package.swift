// swift-tools-version: 6.2
// 6.2 or later: from it SwiftPM lets a version-based dependency use unsafeFlags.
/* ----------------------------------------------------------------------------
Copyright (c) 2018-2026, Microsoft Research, Daan Leijen
This is free software; you can redistribute it and/or modify it under the
terms of the MIT license. A copy of the license can be found in the file
"LICENSE" at the root of this distribution.
-----------------------------------------------------------------------------*/

import PackageDescription

// Extra defines, e.g. `MIMALLOC_DEFINES="MI_SECURE=2 MI_DEBUG=3"`; these take precedence over the traits.
let userDefines = (Context.environment["MIMALLOC_DEFINES"] ?? "")
    .split(whereSeparator: { $0.isWhitespace || $0 == "," })
    .map { "-D\($0)" }

let package = Package(
    name: "mimalloc",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "mimalloc", type: .static, targets: ["Cmimalloc"]),
    ],
    traits: [
        .default(enabledTraits: ["Override"]),
        .trait(name: "Override", description: "Replace malloc, free and friends process-wide (not on Windows)."),
        .trait(name: "Secure", description: "Security mitigations (MI_SECURE=4)."),
        .trait(name: "SecureChecked", description: "SecureBasic plus validated free pointers (MI_SECURE=2)."),
        .trait(name: "SecureBasic", description: "Cheap security mitigations (MI_SECURE=1)."),
        .trait(name: "Debug", description: "Assertions and internal invariant checks (MI_DEBUG=2)."),
        .trait(name: "DebugInDebug", description: "As Debug, in debug builds only."),
        .trait(name: "LocalDynamicTLS", description: "Local-dynamic TLS model, for a dlopen'ed library or musl."),
        .trait(name: "NoTHP", description: "Disable transparent huge pages by default (Linux)."),
        .trait(name: "OptArch", description: "CPU-specific code: haswell, armv8.3-a on Apple, armv8.1-a elsewhere."),
        .trait(name: "MTE", description: "Memory tagging, required at runtime (aarch64 Linux and macOS); implies PAC."),
        .trait(name: "PAC", description: "Pointer authentication, required at runtime (aarch64 Linux and macOS)."),
    ],
    targets: [
        .target(
            name: "Cmimalloc",
            path: ".",
            sources: ["contrib/swift/mimalloc.c"],
            // Not include/: it would export mimalloc-override.h and its malloc/free macros to C clients.
            publicHeadersPath: "contrib/swift/include",
            cSettings: [
                .headerSearchPath("include"),

                // contrib/swift/mimalloc.c maps these to mimalloc defines.
                .define("MI_SWIFT_OVERRIDE", .when(traits: ["Override"])),
                .define("MI_SWIFT_SECURE", .when(traits: ["Secure"])),
                .define("MI_SWIFT_SECURE_CHECKED", .when(traits: ["SecureChecked"])),
                .define("MI_SWIFT_SECURE_BASIC", .when(traits: ["SecureBasic"])),
                .define("MI_SWIFT_DEBUG", .when(traits: ["Debug"])),
                .define("MI_SWIFT_DEBUG", .when(configuration: .debug, traits: ["DebugInDebug"])),
                .define("MI_NO_CXX_NEW_HANDLER", to: "1"),

                .define("MI_DEFAULT_ALLOW_THP", to: "0", .when(traits: ["NoTHP"])),
                .define("MI_SWIFT_MTE", .when(traits: ["MTE"])),
                .define("MI_SWIFT_PAC", .when(traits: ["PAC"])),

                // Compiler flags from CMakeLists.txt.
                .unsafeFlags(["-O3"], .when(configuration: .release)),
                .unsafeFlags(["-fvisibility=hidden", "-Wno-unknown-pragmas", "-mno-outline"]),
                // On all Linux: musl always overrides (contrib/swift/mimalloc.c), and the manifest cannot detect musl.
                .unsafeFlags(["-fno-builtin-malloc"], .when(traits: ["Override"])),
                .unsafeFlags(["-fno-builtin-malloc"], .when(platforms: [.linux])),
                .unsafeFlags(["-ftls-model=initial-exec"]),
                // Must follow initial-exec: the last -ftls-model wins.
                .unsafeFlags(["-ftls-model=local-dynamic"], .when(traits: ["LocalDynamicTLS"])),
                // CMake limits this to arm64; -Xarch_ cannot forward -Xclang, so x86_64 gets it too.
                .unsafeFlags(
                    ["-Xclang", "-fno-split-cold-code"],
                    .when(platforms: [.macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .visionOS])
                ),
                // The manifest cannot see the target architecture; -Xarch_ applies each flag to its own.
                // Apple names arm64 "arm64", other targets "aarch64".
                .unsafeFlags(
                    [
                        "-Xarch_x86_64", "-march=haswell", "-Xarch_x86_64", "-mavx2",
                        "-Xarch_arm64", "-march=armv8.3-a",
                        "-Xarch_aarch64", "-march=armv8.1-a",
                        "-Wno-unused-command-line-argument",
                    ],
                    .when(traits: ["OptArch"])
                ),

                .unsafeFlags(userDefines),
            ]
        ),
        .target(name: "MimallocTestSupport", path: "contrib/swift/TestSupport"),
        .testTarget(
            name: "MimallocTests",
            dependencies: ["Cmimalloc", "MimallocTestSupport"],
            path: "contrib/swift/Tests"
        ),
        // Separate, so only these tests build in C++ interop mode.
        .target(name: "CxxAllocations", dependencies: ["Cmimalloc"], path: "contrib/swift/CxxTests/CxxAllocations"),
        .testTarget(
            name: "MimallocCxxTests",
            dependencies: ["Cmimalloc", "CxxAllocations", "MimallocTestSupport"],
            path: "contrib/swift/CxxTests/Tests",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ]
)
