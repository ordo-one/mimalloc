#!/bin/sh
# Swift package checks for Linux and macOS, with the toolchain's default build system; CI runs it, and so can you.
set -eu
cd "$(dirname "$0")/../.."
unset MIMALLOC_DEFINES  # set below where a run needs it

# `swift package show-traits` lists traits too, but Swift 6.2 lacks it.
command -v jq >/dev/null || { echo "error: jq is required to read the traits from Package.swift" >&2; exit 1; }

# Prints each command; on GitHub Actions also as a collapsible log group.
run() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::group::$*"; else echo "==> $*"; fi
  "$@"
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::endgroup::"; fi
}

# As run, and fails unless the output has `required` and lacks `forbidden`: a test or test-override run where the
# override did not take effect skips suites or prints "override: false", and still exits 0.
run_expecting() {
  required=$1 forbidden=$2
  shift 2
  log=$(mktemp)
  { run "$@" 2>&1 && echo "ci-test: succeeded"; } | tee "$log"
  if ! grep -q '^ci-test: succeeded$' "$log" || ! grep -q -- "$required" "$log" \
    || { [ -n "$forbidden" ] && grep -q -- "$forbidden" "$log"; }; then
    echo "error: $* failed, or its output lacks '$required'${forbidden:+ or has '$forbidden'}" >&2
    exit 1
  fi
  rm -f "$log"
}

run_expecting "Test run with" " skipped" swift test
run_expecting "Test run with" " skipped" swift test -c release

# macOS runs the tests as a bundle loaded into a host process; this is a real executable.
run_expecting "ok, override: true" "" swift run --package-path contrib/swift/test-override
run_expecting "ok, override: false" "" swift run --package-path contrib/swift/test-override --disable-default-traits

# Each trait on top of the default Override, read from Package.swift so a new trait is covered too.
# Assignments, not a pipeline in the for list, so set -e stops on a failing dump-package or jq.
manifest=$(swift package dump-package)
traits=$(printf '%s' "$manifest" | jq -r '.traits[].name | select(. != "default" and . != "Override")')
[ -n "$traits" ] || { echo "error: no traits found in Package.swift" >&2; exit 1; }
for trait in $traits; do
  case "$trait" in
    MTE | PAC)  # running them needs the hardware; other architectures build without them
      run swift build --traits "$trait" ;;
    DebugInDebug | OptArch)  # these act differently in release
      run swift test --traits "Override,$trait"
      run swift test -c release --traits "Override,$trait" ;;
    *)
      run swift test --traits "Override,$trait" ;;
  esac
done
run swift test --disable-default-traits

# The build configuration tests read MIMALLOC_DEFINES too, so they show the defines reached the C build.
run env MIMALLOC_DEFINES="MI_SECURE=3 MI_GUARDED=1" swift test --filter BuildConfiguration

# --disable-xctest: on Linux, LeakSanitizer reports leaks inside libXCTest's empty run.
run swift test --sanitize=address --disable-xctest
run_expecting "ok, override: false" "" swift run --package-path contrib/swift/test-override --sanitize=address

# Linux reports a race at exit until https://github.com/microsoft/mimalloc/pull/1528 lands.
if [ "$(uname -s)" = Darwin ]; then
  run swift test --sanitize=thread --disable-xctest
fi
