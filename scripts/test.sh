#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# swift-testing ships with Command Line Tools but isn't on the default search
# path. Point the compiler at the framework and embed an rpath so the test
# bundle can actually dlopen Testing + lib_TestingInterop at run time.
FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
TESTING_LIBS="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

DYLD_FRAMEWORK_PATH="${FRAMEWORKS}" \
DYLD_LIBRARY_PATH="${TESTING_LIBS}" \
swift test \
    -Xswiftc -F -Xswiftc "${FRAMEWORKS}" \
    -Xlinker -F -Xlinker "${FRAMEWORKS}" \
    -Xlinker -rpath -Xlinker "${FRAMEWORKS}" \
    -Xlinker -rpath -Xlinker "${TESTING_LIBS}" \
    "$@"
