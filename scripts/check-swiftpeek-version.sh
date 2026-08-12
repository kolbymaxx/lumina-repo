#!/usr/bin/env bash
# The version SwiftPeek reports lives in four hand-maintained places. 0.5.1
# shipped with the Settings screen still saying 0.5.0, which means a user
# reading prefs cannot tell which build is installed — and the person who wrote
# the release could not either.
#
# Fails the build when they disagree.
set -euo pipefail
cd "$(dirname "$0")/.."

control_version="$(sed -n 's/^Version: //p' SwiftPeek/control | head -1)"
[ -n "$control_version" ] || { echo "check-swiftpeek-version: no Version in SwiftPeek/control"; exit 1; }
echo "SwiftPeek/control declares $control_version"

fail=0
check() {  # file, human description, grep pattern
    if ! grep -q "$3" "$1"; then
        echo "  MISMATCH  $2"
        echo "            $1 does not mention $control_version"
        grep -on "0\.[0-9]\+\.[0-9]\+" "$1" | head -3 | sed 's/^/            found: /'
        fail=1
    else
        echo "  ok        $2"
    fi
}

check SwiftPeek/src/SPDumpWriter.m \
      "dump tool_version" \
      "\"tool_version\": @\"$control_version\""
check SwiftPeek/src/SPAttach.m \
      "launch probe log line" \
      "launch probe ($control_version)"
check SwiftPeek/layout/Library/PreferenceLoader/Preferences/SwiftPeek.plist \
      "Settings footer" \
      "$control_version:"

if [ "$fail" -ne 0 ]; then
    echo
    echo "Every place a user or a dump can read the version has to agree."
    exit 1
fi
echo "All version strings agree on $control_version"
