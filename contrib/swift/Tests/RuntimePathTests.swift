// One test per Swift runtime allocation path: each forces it and reads back what it stored, and checks the memory came
// from mimalloc where a pointer is reachable. coroutineFrames frees its frames inside the test, so it only checks that
// mimalloc reports no error.
// Sources: https://github.com/swiftlang/swift (runtime/, core/, Concurrency/ and SwiftShims/ under stdlib/public/)
// and https://github.com/swiftlang/swift-foundation.

import Foundation
import MimallocTestSupport
import Testing

extension MimallocTests {
    @Suite(.enabled(if: mimallocReplacesMalloc))
    struct RuntimePaths {
        final class Object {
            let value: Int
            init(_ value: Int) { self.value = value }
        }

        struct WeakReference {
            weak var target: Object?
        }

        struct Wrap<T> {}

        // The frame of a _modify that yields through Dictionary's own modify coroutine does not fit the caller's buffer
        // (test/IRGen/yield_once_type_malloc_coro_frame_old_sdk.swift).
        struct Table {
            var storage: [Int: String] = [:]
            subscript(key: Int) -> String? {
                get { storage[key] }
                // Not inlined, so release builds keep the coroutine and its frame.
                @inline(never) _modify { yield &storage[key] }
            }
        }

        // runtime/HeapObject.cpp swift_allocObject, through runtime/Heap.cpp swift_slowAllocTyped (malloc_type_malloc
        // on macOS 15+); Dictionary and Set storage are class instances too.
        @Test func classInstances() async throws {
            try await expectAllocatedByMimalloc {
                let objects = (0..<1000).map { Object($0) }
                let dictionary = Dictionary(uniqueKeysWithValues: (0..<1000).map { ($0, "\($0)") })
                let set = Set(0..<1000)
                #expect(objects.allSatisfy { inExpectedHeap(Unmanaged.passUnretained($0).toOpaque()) })
                #expect(objects.enumerated().allSatisfy { index, object in object.value == index })
                #expect((0..<1000).allSatisfy { dictionary[$0] == "\($0)" && set.contains($0) })
                return (objects, dictionary, set)
            }
        }

        // Escaping-closure captures and existentials beyond the inline buffer: swift_allocObject with box metadata
        // (runtime/HeapObject.cpp swift_allocBox is only for types without a fixed layout).
        @Test func closureAndExistentialBoxes() async throws {
            try await expectAllocatedByMimalloc {
                let counters: [() -> Int] = (0..<1000).map { start in
                    var count = start
                    return {
                        count += 1
                        return count
                    }
                }
                var values: [Any] = (0..<1000).map { ($0, $0, $0, $0) }  // 32 bytes: the inline buffer holds 24
                // The typed parameter keeps Swift from opening the existential (SE-0352) and passing the tuple.
                let box = withUnsafePointer(to: &values[0]) { (container: UnsafePointer<Any>) in
                    UnsafeRawPointer(container).load(as: UnsafeRawPointer.self)
                }
                #expect(inExpectedHeap(box))
                #expect(counters.enumerated().allSatisfy { start, counter in counter() == start + 1 })
                #expect(values.enumerated().allSatisfy { index, value in
                    guard let tuple = value as? (Int, Int, Int, Int) else { return false }
                    return tuple == (index, index, index, index)
                })
                return (counters, values)
            }
        }

        // runtime/RefCount.cpp allocateSideTable, through include/swift/Runtime/Heap.h swift_cxx_newObject and
        // swift_slowAlloc: the first weak reference to an object moves its reference counts to a side table.
        @Test func weakReferenceSideTables() async throws {
            try await expectAllocatedByMimalloc {
                let targets = (0..<1000).map { Object($0) }
                let references = targets.map { WeakReference(target: $0) }
                #expect(zip(references, targets).allSatisfy { reference, target in reference.target === target })
                return (targets, references)
            }
        }

        // runtime/Heap.cpp swift_slowAlloc never uses plain malloc: alignments up to 16 become AlignedAlloc(16)
        // (posix_memalign, include/swift/Basic/Malloc.h); larger ones go to AlignedAlloc directly.
        @Test(arguments: [16, 32, 64, 4096, 65536, 1 << 22])
        func rawAllocation(_ alignment: Int) async {
            await expectNoMimallocErrors {
                let blocks = blockSizes.map { UnsafeMutableRawPointer.allocate(byteCount: $0, alignment: alignment) }
                for (block, size) in zip(blocks, blockSizes) { fill(block, count: size, seed: size) }
                for (block, size) in zip(blocks, blockSizes) {
                    #expect(inExpectedHeap(block))
                    #expect(Int(bitPattern: block) % alignment == 0)
                    #expect(holdsFill(block, count: size, seed: size))
                }
                blocks.forEach { $0.deallocate() }
            }
        }

        // Concurrency/Task.cpp swift_task_create_common: each task object comes from swift_slowAlloc.
        @Test func tasks() async throws {
            try await expectAllocatedByMimalloc {
                let tasks = (0..<100).map { index in Task { index } }
                #expect(tasks.allSatisfy { inExpectedHeap(unsafeBitCast($0, to: UnsafeRawPointer.self)) })
                var results: [Int] = []
                for task in tasks { results.append(await task.value) }
                #expect(results == Array(0..<100))
                return tasks
            }
        }

        // Concurrency/TaskAlloc.cpp swift_task_alloc: async frames live in malloced slabs of about 1000 bytes
        // (runtime/StackAllocator.h, TaskPrivate.h SlabCapacity), so 40 nested frames span several.
        @Test func taskAllocatorSlabs() async {
            // Returns how many frames held their contents across the suspension and sat in mimalloc's heap.
            func descend(_ depth: Int) async -> Int {
                var frame = (depth, depth, depth, depth, depth, depth, depth, depth)  // held across the suspension
                await Task.yield()
                let deeper = depth > 0 ? await descend(depth - 1) : 0
                let intact = frame.0 == depth && frame.7 == depth
                return deeper + (intact && withUnsafeMutablePointer(to: &frame) { inExpectedHeap($0) } ? 1 : 0)
            }
            await expectNoMimallocErrors {
                #expect(await descend(39) == 40)
            }
        }

        // runtime/Heap.cpp swift_coroFrameAlloc (malloc before macOS 26): coroutine frames too large for the caller's
        // buffer. Whether the frame reaches the heap is up to the compiler; this only checks mimalloc reports no error.
        @Test func coroutineFrames() async {
            await expectNoMimallocErrors {
                var table = Table()
                for key in 0..<1000 {
                    table[key] = "\(key)"
                    table[key]?.append("!")
                }
                #expect((0..<1000).allSatisfy { table[$0] == "\($0)!" })
            }
        }

        // runtime/Metadata.cpp MetadataAllocator: once the 64 KB static pool is used up, 16 KB pages come from
        // allocateRawMetadataMemory (malloc_zone_malloc_with_options on macOS 26+, else swift_slowAlloc).
        @Test func genericMetadata() async throws {
            func wrap<T>(_: T.Type) -> Any.Type { Wrap<T>.self }
            try await expectAllocatedByMimalloc {
                var type: Any.Type = Int.self
                for _ in 0..<2000 { type = wrap(type) }
                #expect(inExpectedHeap(unsafeBitCast(type, to: UnsafeRawPointer.self)))
                return type
            }
        }

        // runtime/ErrorObjectNative.cpp swift_allocError (runtime/ErrorObject.mm on Darwin, through ObjC
        // class_createInstance): a native Swift error is always boxed; an NSError is its own box.
        @Test func errorBoxes() async throws {
            struct Failure: Error {
                let code: Int
                let detail: String
            }
            try await expectAllocatedByMimalloc {
                let errors: [any Error] = (0..<1000).map { Failure(code: $0, detail: "failure \($0)") }
                // An any Error is a single pointer to its box; the typed parameter keeps Swift from opening it.
                let box = withUnsafePointer(to: errors[0]) { (error: UnsafePointer<any Error>) in
                    UnsafeRawPointer(error).load(as: UnsafeRawPointer.self)
                }
                #expect(inExpectedHeap(box))
                #expect(errors.enumerated().allSatisfy { index, error in
                    guard let failure = error as? Failure else { return false }
                    return failure.code == index && failure.detail == "failure \(index)"
                })
                return errors
            }
        }

        // core/KeyPath.swift swift_getKeyPath: a key path with a subscript argument is a new KeyPath object per
        // argument (Builtin.allocWithTailElems, so swift_allocObject), the argument stored in its tail.
        @Test func keyPaths() async throws {
            try await expectAllocatedByMimalloc {
                let array = Array(0..<1000).map { $0 * 3 }
                let paths = (0..<1000).map { \[Int].[$0] }
                #expect(inExpectedHeap(Unmanaged.passUnretained(paths[0]).toOpaque()))
                #expect(paths.enumerated().allSatisfy { index, path in array[keyPath: path] == index * 3 })
                return paths
            }
        }

        // LibcShims.h _swift_stdlib_malloc_size: Array and ManagedBuffer take their capacity from it, String only from
        // 128 bytes up; the test writes all of it, and MI_DEBUG checks padding on free, so an overstated size errors.
        @Test(arguments: [1, 15, 100, 1000, 5000, 100_000])
        func storageFillsReportedCapacity(_ count: Int) async {
            await expectNoMimallocErrors {
                var array = [UInt8]()
                array.reserveCapacity(count)
                #expect(array.capacity >= count)
                array.append(contentsOf: repeatElement(0xCD, count: array.capacity))
                array.withUnsafeBytes { #expect(inExpectedHeap($0.baseAddress)) }
                #expect(array.allSatisfy { $0 == 0xCD })

                var string = ""
                string.reserveCapacity(count)
                for _ in 0..<2 * count { string.append("x") }
                if string.utf8.count > 15 {  // shorter strings are stored inline
                    let checked: Void? = string.utf8.withContiguousStorageIfAvailable {
                        #expect(inExpectedHeap($0.baseAddress))
                    }
                    #expect(checked != nil)
                }
                #expect(string.utf8.count == 2 * count && string.utf8.allSatisfy { $0 == UInt8(ascii: "x") })

                let buffer = ManagedBuffer<Int, UInt8>.create(minimumCapacity: count) { _ in 0 }
                #expect(buffer.capacity >= count)
                #expect(inExpectedHeap(Unmanaged.passUnretained(buffer).toOpaque()))
                buffer.withUnsafeMutablePointerToElements { elements in
                    elements.initialize(repeating: 0xCD, count: buffer.capacity)
                    #expect(UnsafeBufferPointer(start: elements, count: buffer.capacity).allSatisfy { $0 == 0xCD })
                }
            }
        }

        // swift-foundation Sources/FoundationEssentials/Data/Representations/DataStorage.swift: Data grows its buffer
        // with realloc (malloc_type_realloc on Darwin).
        @Test func foundationData() async throws {
            try await expectAllocatedByMimalloc {
                var data = Data()
                for chunk in 0..<100 {
                    data.append(Data(repeating: UInt8(chunk), count: 50_000))
                }
                #expect(data.count == 100 * 50_000)
                #expect((0..<100).allSatisfy { (chunk: Int) -> Bool in
                    let first: Int = chunk * 50_000
                    return data[first] == UInt8(chunk) && data[first + 49_999] == UInt8(chunk)
                })
                data.withUnsafeBytes { #expect(inExpectedHeap($0.baseAddress)) }
                return data
            }
        }
    }
}
