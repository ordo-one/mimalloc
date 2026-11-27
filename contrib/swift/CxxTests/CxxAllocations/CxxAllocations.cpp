#include "CxxAllocations.h"

#include <Cmimalloc.h>
#include <limits>
#include <new>

void* cxxNew(std::size_t size) { return ::operator new(size); }
void cxxDelete(void* pointer) noexcept { ::operator delete(pointer); }

#if defined(_WIN32)
bool cxxOperatorNewIsMimallocs() { return false; }  // Override has no effect on Windows
#else
#include <dlfcn.h>

bool cxxOperatorNewIsMimallocs() {
    void* (*operatorNew)(std::size_t) = &::operator new;
    Dl_info newInfo{}, mimallocInfo{};
    return dladdr(reinterpret_cast<void*>(operatorNew), &newInfo) != 0
        && dladdr(reinterpret_cast<void*>(&mi_malloc), &mimallocInfo) != 0
        && newInfo.dli_fbase == mimallocInfo.dli_fbase;
}
#endif

namespace {
int newHandlerCalls = 0;

// Called by a throwing new that failed; uninstalls itself, so the retry throws std::bad_alloc.
void countingNewHandler() {
    newHandlerCalls++;
    std::set_new_handler(nullptr);
}
}  // namespace

int cxxNewFailureOutcome(bool throwing) {
    constexpr std::size_t impossible = std::numeric_limits<std::size_t>::max() / 2;
    std::set_new_handler(countingNewHandler);
    int outcome = 0;
    if (!throwing) {
        if (::operator new(impossible, std::nothrow) == nullptr) outcome |= CxxNothrowReturnedNull;
    } else {
        try {
            ::operator delete(::operator new(impossible));
        } catch (const std::bad_alloc&) {
            outcome |= CxxThrowingNewThrewBadAlloc;
        }
    }
    if (newHandlerCalls > 0) outcome |= CxxNewHandlerCalled;
    return outcome;
}
