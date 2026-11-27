// The debug and secure levels each trait should give the C build, and the levels it actually reports.

import Cmimalloc
import Foundation

#if Debug || (DebugInDebug && DEBUG)
    private let traitDebugLevel = 2
#else
    private let traitDebugLevel = 0
#endif

#if Secure
    private let traitSecureLevel = 4
#elseif SecureChecked
    private let traitSecureLevel = 2
#elseif SecureBasic
    private let traitSecureLevel = 1
#elseif (MTE || PAC) && arch(arm64)
    private let traitSecureLevel = 2  // include/mimalloc/config.h default with MTE or PAC; arm64 only (mimalloc.c)
#else
    private let traitSecureLevel = 0
#endif

// MIMALLOC_DEFINES wins over the traits (Package.swift); `swift test` passes it on to the test process.
private let definedLevels: [Substring: Int] = Dictionary(
    (ProcessInfo.processInfo.environment["MIMALLOC_DEFINES"] ?? "")
        .split(whereSeparator: { $0.isWhitespace || $0 == "," })
        .compactMap { define in
            let parts = define.split(separator: "=", maxSplits: 1)
            return parts.count == 2 ? Int(parts[1]).map { (parts[0], $0) } : nil
        },
    uniquingKeysWith: { _, last in last })

let expectedDebugLevel = definedLevels["MI_DEBUG"] ?? traitDebugLevel
let expectedSecureLevel = definedLevels["MI_SECURE"] ?? traitSecureLevel

// MI_DEBUG and MI_SECURE have no getter; mi_options_print_out is the only API that reports them,
// as lines like "secure level: 4".
func buildLevels() -> (debug: Int?, secure: Int?) {
    var printed = ""
    withUnsafeMutablePointer(to: &printed) { printed in
        mi_options_print_out(
            { message, printed in
                guard let message, let printed else { return }
                printed.assumingMemoryBound(to: String.self).pointee += String(cString: message)
            }, printed)
    }
    var levels: [String: Int] = [:]
    for line in printed.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.filter { $0 != " " } }
        if parts.count == 2, let value = Int(parts[1]) { levels[parts[0]] = value }
    }
    return (levels["debuglevel"], levels["securelevel"])
}
