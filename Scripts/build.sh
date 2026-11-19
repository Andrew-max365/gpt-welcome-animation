#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$repo_root/dist/GPT Welcome.app}"
if [[ -e "$out" ]]; then
  printf 'Output already exists: %s\n' "$out" >&2
  exit 1
fi

# Compile dependencies only into a disposable directory; the application uses
# the system Swift runtime and Apple frameworks, with no package manager.
temp_root="${BUILD_TEMP_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$temp_root"
temp_root="$(cd "$temp_root" && pwd -P)"
build_tmp="$(mktemp -d "$temp_root/gpt-welcome-build.XXXXXX")"
cleanup() {
  case "$build_tmp" in
    "$temp_root"/gpt-welcome-build.*) /bin/rm -rf -- "$build_tmp" ;;
  esac
}
trap cleanup EXIT
bundle="$build_tmp/GPT Welcome.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$build_tmp/module-cache"

arch="$(uname -m)"
case "$arch" in arm64|x86_64) ;; *) printf 'Unsupported CPU: %s\n' "$arch" >&2; exit 1 ;; esac
/usr/bin/xcrun swiftc -O -target "$arch-apple-macosx14.0" \
  -module-cache-path "$build_tmp/module-cache" \
  "$repo_root/Sources/ColdLaunchGate.swift" \
  "$repo_root/Sources/Motion.swift" \
  "$repo_root/Sources/main.swift" \
  -o "$bundle/Contents/MacOS/GPTWelcome"
/bin/cp "$repo_root/Info.plist" "$bundle/Contents/Info.plist"
/bin/cp "$repo_root/Resources/Welcome-Andrew.html" "$bundle/Contents/Resources/Welcome-Andrew.html"
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
"$bundle/Contents/MacOS/GPTWelcome" --self-test
mkdir -p "$(dirname "$out")"
/bin/mv "$bundle" "$out"
printf 'Built: %s\n' "$out"
