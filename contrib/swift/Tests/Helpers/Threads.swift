// New threads that are joined, not pooled, so a test sees each thread's exit and mimalloc's cleanup for it.

import Foundation

/// Runs `body(index)` on `count` new threads, started one after another, and returns their results once every thread
/// has exited, thread-local destructors and mimalloc's thread cleanup included (Foundation's Thread has no join).
func onNewThreads<T>(_ count: Int, _ body: @escaping @Sendable (Int) -> T) -> [T] {
    let slots = (0..<count).map { _ in ResultSlot<T>() }
    let joins = slots.enumerated().map { index, slot in startThread { slot.value = body(index) } }
    joins.forEach { $0() }
    let results = slots.compactMap(\.value)
    precondition(results.count == count, "a thread returned no result")
    return results
}

// Written by one thread, read after joining it.
private final class ResultSlot<T>: @unchecked Sendable {
    var value: T?
}

private final class ThreadBody {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

// Takes an optional: Darwin passes the context non-optional, Glibc optional.
private func runThreadBody(_ context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let context else { return nil }
    Unmanaged<ThreadBody>.fromOpaque(context).takeRetainedValue().run()
    return nil
}

private func startThread(_ run: @escaping () -> Void) -> () -> Void {
    let context = Unmanaged.passRetained(ThreadBody(run)).toOpaque()
    #if canImport(Darwin)
        var thread: pthread_t?
        precondition(pthread_create(&thread, nil, { runThreadBody($0) }, context) == 0)
        return { precondition(thread.map { pthread_join($0, nil) } == 0) }
    #else
        var thread = pthread_t()
        precondition(pthread_create(&thread, nil, { runThreadBody($0) }, context) == 0)
        return { precondition(pthread_join(thread, nil) == 0) }
    #endif
}
