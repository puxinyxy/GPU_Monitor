#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
source_app="$project_dir/dist/GPU Monitor.app"
applications_dir="/Applications"
install_dir="/Applications/GPU Monitor.app"
installed_executable="$install_dir/Contents/MacOS/GPUMonitor"
bundle_identifier="com.yxy.gpumonitor"

fail() {
    print -u2 "Installation failed: $1"
    exit 1
}

verify_bundle() {
    local bundle=$1
    local observed_identifier
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle" \
        >/dev/null 2>&1 || return 1
    observed_identifier=$(
        /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$bundle/Contents/Info.plist" 2>/dev/null
    ) || return 1
    [[ "$observed_identifier" == "$bundle_identifier" ]]
}

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
[[ "$applications_dir" == "/Applications" ]] || exit 2
"$project_dir/scripts/package_app.sh"
[[ -d "$source_app" ]] || {
    print -u2 "Packaged app not found: $source_app"
    exit 1
}

running_pids=(${(f)"$(installed_pids)"})
if (( ${#running_pids} > 0 )); then
    if ! /usr/bin/osascript \
        -e 'ignoring application responses' \
        -e "tell application id \"$bundle_identifier\" to quit" \
        -e 'end ignoring' >/dev/null; then
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

transaction_dir=$(/usr/bin/mktemp -d "$applications_dir/.gpu-monitor-install.XXXXXX") ||
    fail "could not create the installation staging directory"
[[ -d "$transaction_dir" &&
   "$transaction_dir" == "$applications_dir"/.gpu-monitor-install.* ]] || exit 2
stage_dir="$transaction_dir/GPU Monitor.app.stage"
backup_dir="$transaction_dir/GPU Monitor.app.backup"
[[ "$stage_dir" == "$transaction_dir/GPU Monitor.app.stage" &&
   "$backup_dir" == "$transaction_dir/GPU Monitor.app.backup" ]] || exit 2

cleanup_validated_transaction() {
    [[ -d "$transaction_dir" &&
       "$transaction_dir" == "$applications_dir"/.gpu-monitor-install.* &&
       "$stage_dir" == "$transaction_dir/GPU Monitor.app.stage" &&
       "$backup_dir" == "$transaction_dir/GPU Monitor.app.backup" ]] || exit 2
    if [[ -e "$stage_dir" || -L "$stage_dir" ]]; then
        /bin/rm -rf "$stage_dir" || return 1
    fi
    if [[ -e "$backup_dir" || -L "$backup_dir" ]]; then
        /bin/rm -rf "$backup_dir" || return 1
    fi
    /bin/rmdir "$transaction_dir"
}

fail_before_replacement() {
    local message=$1
    if ! cleanup_validated_transaction; then
        print -u2 "Installation failed: $message"
        print -u2 "Staging cleanup failed. Manual remediation required for the guarded GPU Monitor staging directory."
        exit 1
    fi
    fail "$message"
}

had_existing=0
if [[ -e "$install_dir" || -L "$install_dir" ]]; then
    [[ -d "$install_dir" && ! -L "$install_dir" ]] ||
        fail_before_replacement "the installed GPU Monitor path is not a regular app bundle"
    had_existing=1
fi

if ! /usr/bin/ditto "$source_app" "$stage_dir"; then
    fail_before_replacement "could not copy the candidate into staging"
fi
[[ -d "$stage_dir" && ! -L "$stage_dir" ]] ||
    fail_before_replacement "the staged candidate is not a regular app bundle"
verify_bundle "$stage_dir" ||
    fail_before_replacement "the staged candidate failed signature or bundle-identity verification"

if (( had_existing )); then
    if ! /bin/mv "$install_dir" "$backup_dir"; then
        if ! verify_bundle "$install_dir"; then
            print -u2 "Installation failed: could not create the guarded backup."
            print -u2 "The installed bundle could not be verified. Manual remediation required."
            exit 1
        fi
        fail_before_replacement "could not move the installed bundle into the guarded backup"
    fi
fi

recover_replacement() {
    local message=$1

    if [[ -e "$install_dir" || -L "$install_dir" ]]; then
        /bin/rm -rf "$install_dir" || {
            print -u2 "Installation failed: $message"
            print -u2 "The failed candidate could not be removed. Manual remediation required; the guarded backup was preserved."
            exit 1
        }
    fi

    if (( had_existing )); then
        /bin/mv "$backup_dir" "$install_dir" || {
            print -u2 "Installation failed: $message"
            print -u2 "The previous bundle could not be restored. Manual remediation required; the guarded backup was preserved."
            exit 1
        }
        verify_bundle "$install_dir" || {
            print -u2 "Installation failed: $message"
            print -u2 "The restored bundle could not be verified. Manual remediation required."
            exit 1
        }
    else
        [[ ! -e "$install_dir" && ! -L "$install_dir" ]] || {
            print -u2 "Installation failed: $message"
            print -u2 "The failed candidate remains at the guarded install path. Manual remediation required."
            exit 1
        }
    fi

    if ! cleanup_validated_transaction; then
        print -u2 "Installation failed: $message"
        print -u2 "Recovery succeeded, but guarded staging cleanup requires manual remediation."
        exit 1
    fi
    fail "$message"
}

/bin/mv "$stage_dir" "$install_dir" ||
    recover_replacement "could not atomically replace the installed bundle"
verify_bundle "$install_dir" ||
    recover_replacement "the installed candidate failed final verification"

if ! cleanup_validated_transaction; then
    print -u2 "Installation succeeded, but guarded backup cleanup requires manual remediation."
    exit 1
fi
/usr/bin/open "$install_dir"
