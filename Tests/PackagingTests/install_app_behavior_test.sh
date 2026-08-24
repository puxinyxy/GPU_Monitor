#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h:h}
production_installer="$project_dir/scripts/install_app.sh"
test_root=$(/usr/bin/mktemp -d /tmp/gpu-monitor-install-test.XXXXXX)

[[ -f "$production_installer" ]] || {
    print -u2 "Production installer is missing"
    exit 1
}
[[ -d "$test_root" && "$test_root" == /tmp/gpu-monitor-install-test.* ]] || {
    print -u2 "Unsafe installer-test temp root"
    exit 2
}

cleanup() {
    [[ -n "${test_root:-}" && -d "$test_root" &&
       "$test_root" == /tmp/gpu-monitor-install-test.* ]] || return
    /bin/rm -rf -- "$test_root"
}
trap cleanup EXIT INT TERM

write_fake_commands() {
    local case_root=$1
    local fake_bin="$case_root/fake-bin"
    /bin/mkdir -p "$fake_bin"

    /bin/cat > "$fake_bin/id" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$#" -eq 1 && "$1" == "-u" ]]
print -r -- "501"
EOF

    /bin/cat > "$fake_bin/ps" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_CASE_ROOT:?}"
: "${GPU_MONITOR_INSTALL_TEST_SCENARIO:?}"
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
case_root=$GPU_MONITOR_INSTALL_TEST_CASE_ROOT
scenario=$GPU_MONITOR_INSTALL_TEST_SCENARIO
log_file=$GPU_MONITOR_INSTALL_TEST_LOG
[[ "$case_root" == /tmp/gpu-monitor-install-test.*/* ]]
exact_executable="$case_root/Applications/GPU Monitor.app/Contents/MacOS/GPUMonitor"
print -r -- "ps" >> "$log_file"
case "$scenario" in
    different_uid)
        print -r -- "9001 502 $exact_executable"
        ;;
    different_path)
        print -r -- "9001 501 $case_root/other/GPUMonitor"
        ;;
    apple_failure|timeout)
        print -r -- "9001 501 $exact_executable"
        ;;
    success)
        [[ -f "$case_root/quit-requested" ]] || print -r -- "9001 501 $exact_executable"
        ;;
esac
EOF

    /bin/cat > "$fake_bin/osascript" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_CASE_ROOT:?}"
: "${GPU_MONITOR_INSTALL_TEST_SCENARIO:?}"
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
case_root=$GPU_MONITOR_INSTALL_TEST_CASE_ROOT
scenario=$GPU_MONITOR_INSTALL_TEST_SCENARIO
log_file=$GPU_MONITOR_INSTALL_TEST_LOG
[[ "$case_root" == /tmp/gpu-monitor-install-test.*/* ]]
[[ "$#" -eq 6 &&
   "$1" == "-e" && "$2" == 'ignoring application responses' &&
   "$3" == "-e" && "$4" == 'tell application id "com.yxy.gpumonitor" to quit' &&
   "$5" == "-e" && "$6" == 'end ignoring' ]]
print -r -- "osascript:$2|$4|$6" >> "$log_file"
if [[ "$scenario" == "apple_failure" ]]; then
    exit 42
fi
if [[ "$scenario" == "success" ]]; then
    : > "$case_root/quit-requested"
fi
exit 0
EOF

    /bin/cat > "$fake_bin/sleep" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
print -r -- "sleep:$*" >> "$GPU_MONITOR_INSTALL_TEST_LOG"
EOF

    /bin/cat > "$fake_bin/mktemp" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_CASE_ROOT:?}"
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
case_root=$GPU_MONITOR_INSTALL_TEST_CASE_ROOT
log_file=$GPU_MONITOR_INSTALL_TEST_LOG
[[ "$#" -eq 2 && "$1" == "-d" ]]
[[ "$2" == "$case_root/Applications/.gpu-monitor-install.XXXXXX" ]]
transaction_dir="$case_root/Applications/.gpu-monitor-install.TEST"
[[ ! -e "$transaction_dir" ]]
/bin/mkdir "$transaction_dir"
print -r -- "mktemp:$transaction_dir" >> "$log_file"
print -r -- "$transaction_dir"
EOF

    /bin/cat > "$fake_bin/ditto" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_CASE_ROOT:?}"
: "${GPU_MONITOR_INSTALL_TEST_SCENARIO:?}"
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
case_root=$GPU_MONITOR_INSTALL_TEST_CASE_ROOT
scenario=$GPU_MONITOR_INSTALL_TEST_SCENARIO
log_file=$GPU_MONITOR_INSTALL_TEST_LOG
stage_dir="$case_root/Applications/.gpu-monitor-install.TEST/GPU Monitor.app.stage"
[[ "$#" -eq 2 ]]
[[ "$1" == "${case_root:A}/project/dist/GPU Monitor.app" ]]
[[ "$2" == "$stage_dir" ]]
print -r -- "ditto:$2" >> "$log_file"
[[ "$scenario" == "stage_copy_failure" ]] && exit 43
/bin/mkdir -p "$stage_dir/Contents/MacOS"
print -r -- "candidate" > "$stage_dir/version"
EOF

    /bin/cat > "$fake_bin/codesign" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_CASE_ROOT:?}"
: "${GPU_MONITOR_INSTALL_TEST_SCENARIO:?}"
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
case_root=$GPU_MONITOR_INSTALL_TEST_CASE_ROOT
scenario=$GPU_MONITOR_INSTALL_TEST_SCENARIO
log_file=$GPU_MONITOR_INSTALL_TEST_LOG
target=${@: -1}
stage_dir="$case_root/Applications/.gpu-monitor-install.TEST/GPU Monitor.app.stage"
install_dir="$case_root/Applications/GPU Monitor.app"
print -r -- "codesign:$target" >> "$log_file"
[[ "$target" == "$stage_dir" && "$scenario" == "staged_signature_failure" ]] && exit 44
if [[ "$target" == "$install_dir" && "$scenario" == "final_verification_failure" &&
      "$(<"$install_dir/version")" == "candidate" ]]; then
    exit 45
fi
EOF

    /bin/cat > "$fake_bin/PlistBuddy" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_CASE_ROOT:?}"
: "${GPU_MONITOR_INSTALL_TEST_SCENARIO:?}"
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
case_root=$GPU_MONITOR_INSTALL_TEST_CASE_ROOT
scenario=$GPU_MONITOR_INSTALL_TEST_SCENARIO
log_file=$GPU_MONITOR_INSTALL_TEST_LOG
[[ "$#" -eq 3 && "$1" == "-c" && "$2" == "Print :CFBundleIdentifier" ]]
plist_path=$3
print -r -- "plist:$plist_path" >> "$log_file"
if [[ "$plist_path" == *'.gpu-monitor-install.TEST/GPU Monitor.app.stage/'* &&
      "$scenario" == "staged_identity_failure" ]]; then
    print -r -- "com.example.wrong"
else
    print -r -- "com.yxy.gpumonitor"
fi
EOF

    /bin/cat > "$fake_bin/mv" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_CASE_ROOT:?}"
: "${GPU_MONITOR_INSTALL_TEST_SCENARIO:?}"
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
case_root=$GPU_MONITOR_INSTALL_TEST_CASE_ROOT
scenario=$GPU_MONITOR_INSTALL_TEST_SCENARIO
log_file=$GPU_MONITOR_INSTALL_TEST_LOG
[[ "$#" -eq 2 ]]
install_dir="$case_root/Applications/GPU Monitor.app"
stage_dir="$case_root/Applications/.gpu-monitor-install.TEST/GPU Monitor.app.stage"
backup_dir="$case_root/Applications/.gpu-monitor-install.TEST/GPU Monitor.app.backup"
if [[ "$1" == "$install_dir" && "$2" == "$backup_dir" ]]; then
    print -r -- "mv:backup" >> "$log_file"
elif [[ "$1" == "$stage_dir" && "$2" == "$install_dir" ]]; then
    print -r -- "mv:replace" >> "$log_file"
    [[ "$scenario" == "replacement_failure" ||
       "$scenario" == "no_prior_replacement_failure" ]] && exit 46
elif [[ "$1" == "$backup_dir" && "$2" == "$install_dir" ]]; then
    print -r -- "mv:restore" >> "$log_file"
else
    exit 91
fi
/bin/mv -- "$1" "$2"
EOF

    /bin/cat > "$fake_bin/rm" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_CASE_ROOT:?}"
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
case_root=$GPU_MONITOR_INSTALL_TEST_CASE_ROOT
log_file=$GPU_MONITOR_INSTALL_TEST_LOG
[[ "$#" -eq 2 && "$1" == "-rf" ]]
install_dir="$case_root/Applications/GPU Monitor.app"
stage_dir="$case_root/Applications/.gpu-monitor-install.TEST/GPU Monitor.app.stage"
backup_dir="$case_root/Applications/.gpu-monitor-install.TEST/GPU Monitor.app.backup"
[[ "$2" == "$install_dir" || "$2" == "$stage_dir" || "$2" == "$backup_dir" ]]
print -r -- "rm:$2" >> "$log_file"
/bin/rm -rf -- "$2"
EOF

    /bin/cat > "$fake_bin/rmdir" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_CASE_ROOT:?}"
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
case_root=$GPU_MONITOR_INSTALL_TEST_CASE_ROOT
[[ "$#" -eq 1 && "$1" == "$case_root/Applications/.gpu-monitor-install.TEST" ]]
print -r -- "rmdir:$1" >> "$GPU_MONITOR_INSTALL_TEST_LOG"
/bin/rmdir -- "$1"
EOF

    /bin/cat > "$fake_bin/open" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_CASE_ROOT:?}"
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
case_root=$GPU_MONITOR_INSTALL_TEST_CASE_ROOT
[[ "$#" -eq 1 && "$1" == "$case_root/Applications/GPU Monitor.app" ]]
print -r -- "open:$1" >> "$GPU_MONITOR_INSTALL_TEST_LOG"
EOF

    /bin/chmod 700 "$fake_bin"/*
}

prepare_case() {
    local scenario=$1
    case_root="$test_root/$scenario"
    local fake_bin="$case_root/fake-bin"
    local patched_installer="$case_root/project/scripts/install_app.sh"
    /bin/mkdir -p \
        "$case_root/project/scripts" \
        "$case_root/project/dist/GPU Monitor.app/Contents/MacOS" \
        "$case_root/Applications"
    : > "$case_root/events.log"
    print -r -- "candidate-source" > "$case_root/project/dist/GPU Monitor.app/version"
    if [[ "$scenario" != "no_prior_replacement_failure" ]]; then
        /bin/mkdir -p "$case_root/Applications/GPU Monitor.app/Contents/MacOS"
        print -r -- "old" > "$case_root/Applications/GPU Monitor.app/version"
    fi
    write_fake_commands "$case_root"

    /bin/cat > "$case_root/project/scripts/package_app.sh" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
print -r -- "package" >> "$GPU_MONITOR_INSTALL_TEST_LOG"
EOF
    /bin/chmod 700 "$case_root/project/scripts/package_app.sh"

    /usr/bin/sed \
        -e "s|/Applications|$case_root/Applications|g" \
        -e "s|/usr/bin/id|$fake_bin/id|g" \
        -e "s|/bin/ps|$fake_bin/ps|g" \
        -e "s|/usr/bin/osascript|$fake_bin/osascript|g" \
        -e "s|/bin/sleep|$fake_bin/sleep|g" \
        -e "s|/usr/bin/mktemp|$fake_bin/mktemp|g" \
        -e "s|/usr/bin/ditto|$fake_bin/ditto|g" \
        -e "s|/usr/bin/codesign|$fake_bin/codesign|g" \
        -e "s|/usr/libexec/PlistBuddy|$fake_bin/PlistBuddy|g" \
        -e "s|/bin/mv|$fake_bin/mv|g" \
        -e "s|/bin/rm|$fake_bin/rm|g" \
        -e "s|/bin/rmdir|$fake_bin/rmdir|g" \
        -e "s|/usr/bin/open|$fake_bin/open|g" \
        "$production_installer" > "$patched_installer"
    /bin/chmod 700 "$patched_installer"

    /usr/bin/grep -Fq -- \
        "install_dir=\"$case_root/Applications/GPU Monitor.app\"" \
        "$patched_installer" || {
        print -u2 "Patched installer did not target the sandbox application path"
        exit 3
    }

    local forbidden
    for forbidden in \
        '/usr/bin/id' \
        '/usr/bin/osascript' \
        '/bin/ps' \
        '/bin/sleep' \
        '/usr/bin/mktemp' \
        '/usr/bin/ditto' \
        '/usr/bin/codesign' \
        '/usr/libexec/PlistBuddy' \
        '/bin/mv' \
        '/bin/rm' \
        '/bin/rmdir' \
        '/usr/bin/open'; do
        if /usr/bin/grep -Fq -- "$forbidden" "$patched_installer"; then
            print -u2 "Unsafe production command remained in patched installer: $forbidden"
            exit 3
        fi
    done
}

run_case() {
    local scenario=$1
    local expected_status=$2
    local case_root="$test_root/$scenario"
    local exit_status
    prepare_case "$scenario"

    set +e
    GPU_MONITOR_INSTALL_TEST_CASE_ROOT="$case_root" \
    GPU_MONITOR_INSTALL_TEST_SCENARIO="$scenario" \
    GPU_MONITOR_INSTALL_TEST_LOG="$case_root/events.log" \
        "$case_root/project/scripts/install_app.sh" \
        > "$case_root/stdout.log" 2> "$case_root/stderr.log"
    exit_status=$?
    set -e

    if [[ "$expected_status" == "zero" ]]; then
        (( exit_status == 0 )) || {
            print -u2 "$scenario unexpectedly failed with status $exit_status"
            /bin/cat "$case_root/stderr.log" >&2
            /bin/cat "$case_root/events.log" >&2
            exit 1
        }
    else
        (( exit_status != 0 )) || {
            print -u2 "$scenario unexpectedly succeeded"
            exit 1
        }
    fi
}

assert_version() {
    local scenario=$1
    local expected=$2
    local version_file="$test_root/$scenario/Applications/GPU Monitor.app/version"
    [[ -f "$version_file" && "$(<"$version_file")" == "$expected" ]]
}

assert_transaction_removed() {
    local scenario=$1
    [[ ! -e "$test_root/$scenario/Applications/.gpu-monitor-install.TEST" ]]
}

event_line() {
    local scenario=$1
    local pattern=$2
    /usr/bin/grep -n -- "$pattern" "$test_root/$scenario/events.log" |
        /usr/bin/head -1 |
        /usr/bin/cut -d: -f1
}

run_case no_match zero
assert_version no_match candidate
assert_transaction_removed no_match
print "PASS: no matching process stages and installs without an Apple Event"

run_case different_uid zero
run_case different_path zero
assert_version different_uid candidate
assert_version different_path candidate
print "PASS: different UID or executable path does not match the installed process"

run_case apple_failure nonzero
assert_version apple_failure old
[[ ! -e "$test_root/apple_failure/Applications/.gpu-monitor-install.TEST" ]]
/usr/bin/grep -Fq -- \
    'Unable to request a graceful GPU Monitor quit; installation stopped.' \
    "$test_root/apple_failure/stderr.log"
[[ "$(/usr/bin/grep -c '^osascript:' "$test_root/apple_failure/events.log")" -eq 1 ]]
! /usr/bin/grep -Eq '^(sleep|mktemp|ditto|mv|rm|open):' \
    "$test_root/apple_failure/events.log"
print "PASS: Apple Event failure preserves the installed bundle"

run_case timeout nonzero
assert_version timeout old
[[ ! -e "$test_root/timeout/Applications/.gpu-monitor-install.TEST" ]]
/usr/bin/grep -Fq -- \
    'The installed GPU Monitor copy did not quit gracefully; installation stopped.' \
    "$test_root/timeout/stderr.log"
! /usr/bin/grep -Fq -- \
    'Unable to request a graceful GPU Monitor quit; installation stopped.' \
    "$test_root/timeout/stderr.log"
[[ "$(/usr/bin/grep -c '^osascript:' "$test_root/timeout/events.log")" -eq 1 ]]
[[ "$(/usr/bin/grep -c '^sleep:0.1$' "$test_root/timeout/events.log")" -eq 50 ]]
! /usr/bin/grep -Eq '^(mktemp|ditto|mv|rm|open):' \
    "$test_root/timeout/events.log"
print "PASS: graceful-quit timeout preserves the installed bundle"

for scenario in stage_copy_failure staged_signature_failure staged_identity_failure; do
    run_case "$scenario" nonzero
    assert_version "$scenario" old
    assert_transaction_removed "$scenario"
done
print "PASS: stage copy, signature, and identity failures preserve the old bundle"

run_case replacement_failure nonzero
assert_version replacement_failure old
assert_transaction_removed replacement_failure
[[ "$(event_line replacement_failure '^mv:restore$')" -gt 0 ]]
print "PASS: replacement failure restores and verifies the old bundle"

run_case final_verification_failure nonzero
assert_version final_verification_failure old
assert_transaction_removed final_verification_failure
[[ "$(event_line final_verification_failure '^mv:restore$')" -gt 0 ]]
print "PASS: final verification failure removes the candidate and restores the old bundle"

run_case no_prior_replacement_failure nonzero
[[ ! -e "$test_root/no_prior_replacement_failure/Applications/GPU Monitor.app" ]]
assert_transaction_removed no_prior_replacement_failure
print "PASS: failed replacement with no prior app leaves no corrupt final bundle"

run_case success zero
assert_version success candidate
assert_transaction_removed success
/usr/bin/grep -Fxq -- \
    'osascript:ignoring application responses|tell application id "com.yxy.gpumonitor" to quit|end ignoring' \
    "$test_root/success/events.log"
quit_line=$(event_line success '^osascript:')
stage_line=$(event_line success '^ditto:')
stage_verify_line=$(event_line success '^codesign:.*stage$')
backup_line=$(event_line success '^mv:backup$')
replace_line=$(event_line success '^mv:replace$')
final_verify_line=$(event_line success '^codesign:.*/GPU Monitor.app$')
backup_cleanup_line=$(event_line success '^rm:.*backup$')
open_line=$(event_line success '^open:')
(( quit_line < stage_line &&
   stage_line < stage_verify_line &&
   stage_verify_line < backup_line &&
   backup_line < replace_line &&
   replace_line < final_verify_line &&
   final_verify_line < backup_cleanup_line &&
   backup_cleanup_line < open_line ))
print "PASS: success orders quit, stage verification, backup, replacement, final verification, cleanup, and open"

print "All installer behavior checks passed"
