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
    [[ -n "${test_root:-}" && -d "$test_root" && "$test_root" == /tmp/gpu-monitor-install-test.* ]] || return
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
exact_executable="$case_root/install/GPU Monitor.app/Contents/MacOS/GPUMonitor"
print -r -- "ps" >> "$log_file"
case "$scenario" in
    no_match)
        ;;
    different_uid)
        print -r -- "9001 502 $exact_executable"
        ;;
    different_path)
        print -r -- "9001 501 $case_root/other/GPUMonitor"
        ;;
    apple_failure|timeout)
        print -r -- "9001 501 $exact_executable"
        ;;
    graceful)
        [[ -f "$case_root/quit-requested" ]] || print -r -- "9001 501 $exact_executable"
        ;;
    *)
        exit 90
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
[[ "$#" -eq 2 && "$1" == "-e" ]]
[[ "$2" == 'tell application id "com.yxy.gpumonitor" to quit' ]]
print -r -- "osascript:$2" >> "$log_file"
if [[ "$scenario" == "apple_failure" ]]; then
    exit 42
fi
if [[ "$scenario" == "graceful" ]]; then
    : > "$case_root/quit-requested"
fi
EOF

    /bin/cat > "$fake_bin/sleep" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
print -r -- "sleep:$*" >> "$GPU_MONITOR_INSTALL_TEST_LOG"
EOF

    /bin/cat > "$fake_bin/rm" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_CASE_ROOT:?}"
: "${GPU_MONITOR_INSTALL_TEST_SCENARIO:?}"
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
case_root=$GPU_MONITOR_INSTALL_TEST_CASE_ROOT
scenario=$GPU_MONITOR_INSTALL_TEST_SCENARIO
log_file=$GPU_MONITOR_INSTALL_TEST_LOG
[[ "$case_root" == /tmp/gpu-monitor-install-test.*/* ]]
[[ "$#" -eq 2 && "$1" == "-rf" ]]
[[ "$2" == "$case_root/install/GPU Monitor.app" ]]
if [[ "$scenario" == "graceful" ]]; then
    [[ -f "$case_root/quit-requested" ]]
fi
print -r -- "rm:$2" >> "$log_file"
EOF

    /bin/cat > "$fake_bin/ditto" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_CASE_ROOT:?}"
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
case_root=$GPU_MONITOR_INSTALL_TEST_CASE_ROOT
log_file=$GPU_MONITOR_INSTALL_TEST_LOG
[[ "$case_root" == /tmp/gpu-monitor-install-test.*/* ]]
print -r -- "ditto-attempt:$*" >> "$log_file"
[[ "$#" -eq 2 ]]
[[ "$1" == "${case_root:A}/project/dist/GPU Monitor.app" ]]
[[ "$2" == "$case_root/install/GPU Monitor.app" ]]
print -r -- "ditto:$2" >> "$log_file"
: > "$case_root/overwrite-performed"
EOF

    /bin/cat > "$fake_bin/codesign" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
print -r -- "codesign:$*" >> "$GPU_MONITOR_INSTALL_TEST_LOG"
EOF

    /bin/cat > "$fake_bin/open" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
print -r -- "open:$*" >> "$GPU_MONITOR_INSTALL_TEST_LOG"
EOF

    /bin/chmod 700 "$fake_bin"/*
}

prepare_case() {
    local scenario=$1
    local case_root="$test_root/$scenario"
    local fake_bin="$case_root/fake-bin"
    local patched_installer="$case_root/project/scripts/install_app.sh"
    /bin/mkdir -p \
        "$case_root/project/scripts" \
        "$case_root/project/dist/GPU Monitor.app/Contents/MacOS" \
        "$case_root/install"
    : > "$case_root/events.log"
    write_fake_commands "$case_root"

    /bin/cat > "$case_root/project/scripts/package_app.sh" <<'EOF'
#!/bin/zsh
set -euo pipefail
: "${GPU_MONITOR_INSTALL_TEST_LOG:?}"
print -r -- "package" >> "$GPU_MONITOR_INSTALL_TEST_LOG"
EOF
    /bin/chmod 700 "$case_root/project/scripts/package_app.sh"

    /usr/bin/sed \
        -e "s|/Applications/GPU Monitor.app|$case_root/install/GPU Monitor.app|g" \
        -e "s|/usr/bin/id|$fake_bin/id|g" \
        -e "s|/bin/ps|$fake_bin/ps|g" \
        -e "s|/usr/bin/osascript|$fake_bin/osascript|g" \
        -e "s|/bin/sleep|$fake_bin/sleep|g" \
        -e "s|/usr/bin/ditto|$fake_bin/ditto|g" \
        -e "s|/usr/bin/codesign|$fake_bin/codesign|g" \
        -e "s|/usr/bin/open|$fake_bin/open|g" \
        -e "s|rm -rf \"\$install_dir\"|\"$fake_bin/rm\" -rf \"\$install_dir\"|g" \
        "$production_installer" > "$patched_installer"
    /bin/chmod 700 "$patched_installer"

    local forbidden
    for forbidden in \
        '/Applications/GPU Monitor.app' \
        '/usr/bin/id' \
        '/usr/bin/osascript' \
        '/bin/ps' \
        '/bin/sleep' \
        '/usr/bin/ditto' \
        '/usr/bin/codesign' \
        '/usr/bin/open' \
        'rm -rf "$install_dir"'; do
        if /usr/bin/grep -Fq -- "$forbidden" "$patched_installer"; then
            print -u2 "Unsafe production command remained in patched installer: $forbidden"
            exit 3
        fi
    done
}

run_case() {
    local scenario=$1
    local expected_status=$2
    local expected_overwrite=$3
    local expected_event_count=$4
    local case_root="$test_root/$scenario"
    local log_file="$case_root/events.log"
    local exit_status event_count
    prepare_case "$scenario"

    set +e
    GPU_MONITOR_INSTALL_TEST_CASE_ROOT="$case_root" \
    GPU_MONITOR_INSTALL_TEST_SCENARIO="$scenario" \
    GPU_MONITOR_INSTALL_TEST_LOG="$log_file" \
        "$case_root/project/scripts/install_app.sh" \
        > "$case_root/stdout.log" 2> "$case_root/stderr.log"
    exit_status=$?
    set -e

    if [[ "$expected_status" == "zero" ]]; then
        (( exit_status == 0 )) || {
            print -u2 "$scenario unexpectedly failed with status $exit_status"
            /bin/cat "$case_root/stderr.log" >&2
            /bin/cat "$case_root/stdout.log" >&2
            /bin/cat "$log_file" >&2
            exit 1
        }
    else
        (( exit_status != 0 )) || {
            print -u2 "$scenario unexpectedly succeeded"
            exit 1
        }
    fi

    if [[ "$expected_overwrite" == "yes" ]]; then
        [[ -f "$case_root/overwrite-performed" ]] || {
            print -u2 "$scenario did not reach the sandbox overwrite"
            exit 1
        }
    else
        [[ ! -f "$case_root/overwrite-performed" ]] || {
            print -u2 "$scenario overwrote despite a fail-closed expectation"
            exit 1
        }
        ! /usr/bin/grep -Eq '^(rm|ditto):' "$log_file" || {
            print -u2 "$scenario reached an overwrite command"
            exit 1
        }
    fi

    event_count=$(/usr/bin/grep -c '^osascript:' "$log_file" || true)
    [[ "$event_count" == "$expected_event_count" ]] || {
        print -u2 "$scenario Apple Event count was $event_count, expected $expected_event_count"
        exit 1
    }
}

assert_graceful_order() {
    local log_file="$test_root/graceful/events.log"
    local quit_line rm_line ditto_line
    quit_line=$(/usr/bin/grep -n '^osascript:' "$log_file" | /usr/bin/head -1)
    rm_line=$(/usr/bin/grep -n '^rm:' "$log_file" | /usr/bin/head -1)
    ditto_line=$(/usr/bin/grep -n '^ditto:' "$log_file" | /usr/bin/head -1)
    [[ -n "$quit_line" && -n "$rm_line" && -n "$ditto_line" ]]
    (( ${quit_line%%:*} < ${rm_line%%:*} && ${rm_line%%:*} < ${ditto_line%%:*} ))
}

run_case no_match zero yes 0
print "PASS: no matching process skips Apple Event and installs"

run_case different_uid zero yes 0
run_case different_path zero yes 0
print "PASS: different UID or executable path does not match the installed process"

run_case apple_failure nonzero no 1
print "PASS: Apple Event failure prevents overwrite"

run_case timeout nonzero no 1
print "PASS: graceful-quit timeout prevents overwrite"

run_case graceful zero yes 1
assert_graceful_order
print "PASS: exact installed process is overwritten only after graceful quit"

print "All installer behavior checks passed"
