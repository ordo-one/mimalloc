// C++ code in a Swift process allocates with mimalloc's own operator new (src/alloc/alloc-override.c): on Linux by
// symbol interposition, on macOS as an exported definition that wins over libc++abi's weak one.

import Cmimalloc
import CxxAllocations
import CxxStdlib
import Foundation
import MimallocTestSupport
import Testing

@Suite(.enabled(if: mimallocReplacesMalloc)) struct OperatorNew {
    @Test func standardLibraryContainers() {
        var vector = IntVector()
        for value in 0..<1000 { vector.push_back(Int32(value)) }
        #expect(mi_is_in_heap_region(vector.__dataUnsafe()))
        #expect((0..<1000).allSatisfy { vector[$0] == Int32($0) })

        let string = std.string(String(repeating: "x", count: 100))  // beyond the inline buffer
        #expect(mi_is_in_heap_region(string.__c_strUnsafe()))
        #expect(String(string) == String(repeating: "x", count: 100))
    }

    @Test func newAndDelete() throws {
        #expect(cxxOperatorNewIsMimallocs())
        let block = try #require(cxxNew(100))
        #expect(mi_is_in_heap_region(block))
        cxxDelete(block)
    }

    // Exit tests from here on: mimalloc reports each failed request process-wide, which the serialized suites of
    // MimallocTests count when linked into the same process, and a failing throwing new may abort.

    // mimalloc's nothrow new is mi_malloc: no new handler, null on failure.
    @Test func nothrowNewFailsWithNull() async {
        await #expect(processExitsWith: .exitCode(CxxNothrowReturnedNull)) {
            exit(cxxNewFailureOutcome(false))
        }
    }

    // What C++ requires. mimalloc's operator new is compiled as C here: it calls no handler (MI_NO_CXX_NEW_HANDLER)
    // and aborts instead of throwing (src/alloc/alloc.c mi_new_fail).
    @Test func throwingNewCallsHandlerThenThrows() async {
        await withKnownIssue("mimalloc's operator new aborts in a C build") {
            await #expect(processExitsWith: .exitCode(CxxThrowingNewThrewBadAlloc | CxxNewHandlerCalled)) {
                disableCoreDumps()
                exit(cxxNewFailureOutcome(true))
            }
        }
    }
}
