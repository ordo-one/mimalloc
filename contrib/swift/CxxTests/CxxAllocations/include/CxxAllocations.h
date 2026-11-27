// C++ allocations for the C++ interop tests: compiled by clang++, so they call operator new as any C++ library would.

#pragma once

#include <cstddef>
#include <vector>

// Swift can only name a specialized class template through an alias.
using IntVector = std::vector<int>;

void* cxxNew(std::size_t size);
void cxxDelete(void* pointer) noexcept;

/// Whether the operator new(size_t) that C++ code here binds to is in the same binary as mi_malloc.
bool cxxOperatorNewIsMimallocs();

enum : int {
    CxxNothrowReturnedNull = 1,
    CxxThrowingNewThrewBadAlloc = 2,
    CxxNewHandlerCalled = 4,
};

/// Requests an impossible size from the nothrow or the throwing operator new, with a new handler installed, and
/// returns the bits above. A failing throwing new may abort, so call it in an exit test.
int cxxNewFailureOutcome(bool throwing);
