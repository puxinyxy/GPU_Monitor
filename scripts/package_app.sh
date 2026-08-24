#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
swift build -c release --package-path "$project_dir" --product GPUMonitor
app_dir="$project_dir/dist/GPU Monitor.app"
[[ "$app_dir" == "$project_dir/dist/GPU Monitor.app" ]] || exit 2
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
ditto "$project_dir/.build/release/GPUMonitor" "$app_dir/Contents/MacOS/GPUMonitor"
ditto "$project_dir/packaging/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
