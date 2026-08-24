#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
source_app="$project_dir/dist/GPU Monitor.app"
install_dir="/Applications/GPU Monitor.app"
installed_executable="$install_dir/Contents/MacOS/GPUMonitor"
bundle_identifier="com.yxy.gpumonitor"

installed_pids() {
    local current_uid process_pid process_uid process_executable
    current_uid=$(/usr/bin/id -u)
    /bin/ps -axo pid=,uid=,comm= | while read -r process_pid process_uid process_executable; do
        if [[ "$process_uid" == "$current_uid" && "$process_executable" == "$installed_executable" ]]; then
            print -r -- "$process_pid"
        fi
    done
}

[[ "$install_dir" == "/Applications/GPU Monitor.app" ]] || exit 2
"$project_dir/scripts/package_app.sh"
[[ -d "$source_app" ]] || {
    print -u2 "Packaged app not found: $source_app"
    exit 1
}

running_pids=(${(f)"$(installed_pids)"})
if (( ${#running_pids} > 0 )); then
    if ! /usr/bin/osascript -e "tell application id \"$bundle_identifier\" to quit" >/dev/null; then
        print -u2 "Unable to request a graceful GPU Monitor quit; installation stopped."
        exit 1
    fi
    for _ in {1..50}; do
        running_pids=(${(f)"$(installed_pids)"})
        (( ${#running_pids} == 0 )) && break
        /bin/sleep 0.1
    done
    running_pids=(${(f)"$(installed_pids)"})
    if (( ${#running_pids} > 0 )); then
        print -u2 "The installed GPU Monitor copy did not quit gracefully; installation stopped."
        exit 1
    fi
fi

rm -rf "$install_dir"
/usr/bin/ditto "$source_app" "$install_dir"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$install_dir"
/usr/bin/open "$install_dir"
