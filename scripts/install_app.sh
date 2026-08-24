#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
source_app="$project_dir/dist/GPU Monitor.app"
install_dir="/Applications/GPU Monitor.app"

[[ "$install_dir" == "/Applications/GPU Monitor.app" ]] || exit 2
"$project_dir/scripts/package_app.sh"
[[ -d "$source_app" ]] || {
    print -u2 "Packaged app not found: $source_app"
    exit 1
}

if /usr/bin/pgrep -x GPUMonitor >/dev/null 2>&1; then
    /usr/bin/pkill -x GPUMonitor
    for _ in {1..20}; do
        /usr/bin/pgrep -x GPUMonitor >/dev/null 2>&1 || break
        /bin/sleep 0.1
    done
    if /usr/bin/pgrep -x GPUMonitor >/dev/null 2>&1; then
        print -u2 "GPU Monitor is still running; installation stopped."
        exit 1
    fi
fi

rm -rf "$install_dir"
/usr/bin/ditto "$source_app" "$install_dir"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$install_dir"
/usr/bin/open "$install_dir"
