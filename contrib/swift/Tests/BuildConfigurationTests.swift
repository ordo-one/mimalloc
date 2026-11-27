// Each package trait reaches the C build: debug and secure levels, the stats layout Swift imports, huge pages.

import Cmimalloc
import Foundation
import Testing

extension MimallocTests {
    @Suite struct BuildConfiguration {
        @Test func traitsSetBuildLevels() {
            let levels = buildLevels()
            #expect(levels.debug == expectedDebugLevel)
            #expect(levels.secure == expectedSecureLevel)
        }

        // mi_stats_get rejects a mi_stats_t whose size or version differs from the compiled library's.
        @Test func statsLayoutMatchesC() {
            var stats = mi_stats_t()
            mi_stats_init(&stats)
            #expect(mi_stats_get(&stats))
        }

        #if NoTHP
            @Test func noTHPDisablesHugePages() {
                #expect(mi_option_get(mi_option_allow_thp) == 0)
            }
        #endif
    }
}
