#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
folder="$root/tweak/Sources/Features/NowPlaying"
output="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/spoti-native-audio-smoke"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -parse-as-library -O \
  -framework Foundation -framework CoreMedia -framework JavaScriptCore -framework VideoToolbox \
  "$folder/NativeAudioResolver.swift" \
  "$folder/NativeYouTubeLocal.swift" \
  "$folder/NativeYouTubeResources.swift" \
  "$root/scripts/native_audio_smoke.swift" -o "$output"
"$output" --fixture "$root/scripts/native-audio-search.fixture.json" "$@"
