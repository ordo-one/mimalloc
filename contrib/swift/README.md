# mimalloc for Swift

Swift package for [mimalloc](https://github.com/microsoft/mimalloc), built from the sources in this repository.

## Usage

Requires Swift 6.2 or later, and macOS 15 or later; packages that depend on it must declare `.macOS(.v15)` or later in `platforms`.

Add the product to an executable target:

```swift
dependencies: [
    .package(url: "https://github.com/microsoft/mimalloc", from: "3.7.1"),
],
targets: [
    .executableTarget(
        name: "MyServer",
        dependencies: [.product(name: "mimalloc", package: "mimalloc")]
    ),
]
```

The default `Override` trait replaces `malloc`, `free` and friends for the whole process on every platform except Windows: Swift runtime, Foundation and C libraries all allocate from mimalloc, including libraries loaded later with `dlopen`.

Tested on macOS, Linux (glibc) and the Swift static Linux SDK. Windows is built in CI but not run, and `Override` has no effect there. Android, iOS and the other Apple platforms are untested.

Only the executable, and static libraries linked into it, may depend on the product. A dynamic library or plugin that depends on it too links a second copy of mimalloc, which receives pointers the first one allocated; with the default build system the graph does not link (`linked as a static library by ... This will result in duplication of library code`). Libraries and plugins need no dependency: they allocate from the executable's mimalloc.

On musl (the Swift static Linux SDK) the package always overrides, with or without the trait: the SDK's musl already allocates with a bundled mimalloc 2.x, which this one replaces, and the two copies cannot link side by side.

Under ASan and TSan (`swift build --sanitize=address`, `swift build --sanitize=thread`) `Override` is off: the sanitizer replaces `malloc` itself to track every allocation. The mimalloc API still works there and is annotated for the sanitizer (`MI_TRACK_ASAN`, `MI_TSAN`).

`Override` also replaces C++ `operator new` and `delete`. This `operator new` never calls a `std::set_new_handler` handler (`MI_NO_CXX_NEW_HANDLER`), and when an allocation fails it aborts the process instead of throwing `std::bad_alloc`, because the package compiles mimalloc as C.

The C API (`mi_malloc`, `mi_heap_new`, `mi_stats_get`, ...) is available with `import Cmimalloc`, and to C and C++ targets with `#include <Cmimalloc.h>`; see the [API documentation](https://microsoft.github.io/mimalloc/).

## Traits

Build options are package traits:

- `Override` (default): replace `malloc` process-wide, see above.
- `Secure`, `SecureChecked`, `SecureBasic`: `MI_SECURE` 4, 2 and 1; the highest enabled level wins.
- `Debug`: assertions and invariant checks (`MI_DEBUG=2`); `DebugInDebug` only in debug builds. Otherwise mimalloc builds with `MI_DEBUG=0` and `NDEBUG`.
- `LocalDynamicTLS`: `-ftls-model=local-dynamic`, for mimalloc inside a `dlopen`ed library. On musl (Swift static Linux SDK) enable it unless the executable is fully static; the manifest cannot detect musl.
- `NoTHP`: no transparent huge pages by default on Linux.
- `OptArch`: architecture specific optimizations, as `-DMI_OPT_ARCH=ON`: x86_64 `-march=haswell -mavx2`, arm64 `-march=armv8.3-a` on Apple platforms and `-march=armv8.1-a` elsewhere. The binary then requires those CPUs.
- `MTE`, `PAC`: memory tagging and pointer authentication, required at runtime (aarch64 Linux and macOS); other architectures, such as the x86_64 half of a universal build, build without them. On macOS, MTE also needs the executable signed with the entitlements in `cmake/mte-entitlements.plist`.

```swift
.package(url: "https://github.com/microsoft/mimalloc", from: "3.7.1", traits: ["Override", "SecureBasic"]),
```

Traits unify across the dependency graph: if any package enables `Override`, the whole process gets it. A package that uses the mimalloc API in a static library should therefore disable the default traits and leave the choice to the executable:

```swift
.package(url: "https://github.com/microsoft/mimalloc", from: "3.7.1", traits: []),
```

## Other options

Defines without a trait go through the `MIMALLOC_DEFINES` environment variable at build time, e.g. `MIMALLOC_DEFINES="MI_SECURE=2 MI_GUARDED=1" swift build`; these take precedence over the traits. It is read from the environment of whatever evaluates the manifest, also when mimalloc is a dependency, so a terminal build and an Xcode build can differ. A define here is passed as is: `MI_MALLOC_OVERRIDE` bypasses the checks that keep the override off under sanitizers and on Windows. Runtime options are the usual `MIMALLOC_*` environment variables or `mi_option_set`.

## Test

```sh
swift test
contrib/swift/ci-test.sh  # what CI runs: every trait, test-override and the sanitizers; needs jq
swift run --package-path contrib/swift/test-override  # a separate package using this one as an application would
```
