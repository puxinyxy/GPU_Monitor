#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h:h}
production_provisioner="$project_dir/scripts/provision_ssh.sh"
fake_ssh="$project_dir/Tests/PackagingTests/fixtures/fake_ssh.sh"
fake_nvidia_smi="$project_dir/Tests/PackagingTests/fixtures/fake_nvidia_smi.sh"
test_root=$(/usr/bin/mktemp -d "${TMPDIR%/}/gpu-monitor-provision-tests.XXXXXX")
provisioner="$test_root/instrumented-provision_ssh.sh"
failures=0
valid_output=$'0, GPU-1234, Test GPU, 0, 12, 24576, 35\n\n__GPU_MONITOR_PROCESSES__\n'
restrictions='no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding'
authorized_options_line=$(/usr/bin/awk '/^no-agent-forwarding,.*command="/ { print; exit }' "$production_provisioner")
forced_command="${authorized_options_line#*command=\"}"
forced_command="${forced_command%\"}"
[[ -n "$forced_command" && "$forced_command" != "$authorized_options_line" ]] || {
    print -u2 "FAIL: could not extract the production forced command"
    exit 1
}

assignment_count=$(/usr/bin/grep -Fxc -- 'ssh_bin="/usr/bin/ssh"' "$production_provisioner" || true)
if [[ "$assignment_count" != "1" ]]; then
    print -u2 "FAIL: expected exactly one fixed production ssh_bin assignment, found $assignment_count"
    exit 1
fi
/usr/bin/sed "s|^ssh_bin=\"/usr/bin/ssh\"$|ssh_bin=\"$fake_ssh\"|" "$production_provisioner" > "$provisioner"
/bin/chmod 755 "$provisioner"
instrumented_count=$(/usr/bin/grep -Fxc -- "ssh_bin=\"$fake_ssh\"" "$provisioner" || true)
remaining_production_count=$(/usr/bin/grep -Fxc -- 'ssh_bin="/usr/bin/ssh"' "$provisioner" || true)
if [[ "$instrumented_count" != "1" || "$remaining_production_count" != "0" ]]; then
    print -u2 "FAIL: instrumented copy did not replace exactly one fixed SSH assignment"
    exit 1
fi

cleanup() {
    [[ "$test_root" == "${TMPDIR%/}/gpu-monitor-provision-tests."* ]] || return 1
    /bin/rm -rf "$test_root"
}
trap cleanup EXIT

forced_command_bin="$test_root/forced-command-bin"
/bin/mkdir -p "$forced_command_bin"
/bin/cp "$fake_nvidia_smi" "$forced_command_bin/nvidia-smi"
/bin/chmod 755 "$forced_command_bin/nvidia-smi"

record_failure() {
    print -u2 "FAIL: $1"
    failures=$((failures + 1))
}

record_pass() {
    print "PASS: $1"
}

run_forced_command() {
    /usr/bin/env \
        PATH="$forced_command_bin:/usr/bin:/bin" \
        GPU_MONITOR_TEST_GPU_STATUS="${gpu_query_status:-0}" \
        GPU_MONITOR_TEST_COMPUTE_STATUS="${compute_query_status:-0}" \
        /bin/sh -c "$forced_command"
}

gpu_query_status=17
if forced_output=$(run_forced_command 2>&1); then
    record_failure "GPU query failure makes the forced command fail"
elif [[ "$?" != "17" || "$forced_output" == *"__GPU_MONITOR_PROCESSES__"* ]]; then
    record_failure "GPU query failure is propagated before the marker"
else
    record_pass "GPU query failure is propagated before the marker"
fi
unset gpu_query_status

compute_query_status=23
if forced_output=$(run_forced_command 2>&1); then
    record_failure "compute query failure makes the forced command fail"
elif [[ "$?" != "23" || "$forced_output" != *"__GPU_MONITOR_PROCESSES__"* ]]; then
    record_failure "compute query failure is propagated after the marker"
else
    record_pass "compute query failure is propagated after the marker"
fi
unset compute_query_status

if forced_output=$(run_forced_command 2>&1) &&
    [[ "$forced_output" == 0,* ]] &&
    [[ "$forced_output" == *$'\n__GPU_MONITOR_PROCESSES__' ]]; then
    record_pass "empty successful compute output remains a valid free-GPU sample"
else
    record_failure "empty successful compute output remains a valid free-GPU sample"
fi

new_case() {
    local name=$1
    case_root="$test_root/$name"
    case_home="$case_root/local-home"
    remote_home="$case_root/remote-home"
    ssh_log="$case_root/ssh.log"
    stdout_log="$case_root/stdout.log"
    stderr_log="$case_root/stderr.log"
    /bin/mkdir -p "$case_home/Library/Application Support/GPUMonitor" "$remote_home/.ssh"
    : > "$ssh_log"

    /usr/bin/ssh-keygen -q -t ed25519 -N "" -f "$case_root/host-key"
    local host_public="$(<"$case_root/host-key.pub")"
    local host_type="${host_public%% *}"
    local host_remainder="${host_public#* }"
    local host_blob="${host_remainder%% *}"
    {
        print -r -- "[122.207.108.8]:10122 $host_type $host_blob"
        print -r -- "[122.207.108.8]:10165 $host_type $host_blob"
    } > "$case_home/Library/Application Support/GPUMonitor/known_hosts"
}

prepare_identity() {
    /bin/mkdir -p "$case_home/.ssh"
    /usr/bin/ssh-keygen -q -t ed25519 -N "" -C "gpu-monitor-restricted" -f "$case_home/.ssh/gpu_monitor_ed25519"
}

trusted_public_parts() {
    local derived
    derived=$(/usr/bin/ssh-keygen -y -f "$case_home/.ssh/gpu_monitor_ed25519")
    trusted_type="${derived%% *}"
    local remainder="${derived#* }"
    trusted_blob="${remainder%% *}"
    expected_authorized_line="$restrictions,command=\"$forced_command\" $trusted_type $trusted_blob gpu-monitor-restricted"
}

run_provisioner() {
    /usr/bin/env \
        HOME="$case_home" \
        GPU_MONITOR_PROVISIONING_TESTING=1 \
        GPU_MONITOR_TEST_REMOTE_HOME="$remote_home" \
        GPU_MONITOR_TEST_SSH_LOG="$ssh_log" \
        GPU_MONITOR_TEST_MONITOR_OUTPUT="${monitor_output:-$valid_output}" \
        GPU_MONITOR_TEST_FORCED_OUTPUT="${forced_output:-${monitor_output:-$valid_output}}" \
        GPU_MONITOR_TEST_FORWARD_ALLOWED="${forward_allowed:-0}" \
        GPU_MONITOR_TEST_FORWARD_UNRELATED_FAILURE="${forward_unrelated_failure:-0}" \
        "$provisioner" >"$stdout_log" 2>"$stderr_log"
}

expect_failure_without_ssh() {
    local description=$1
    if run_provisioner; then
        record_failure "$description (unexpected success)"
    elif [[ -s "$ssh_log" ]]; then
        record_failure "$description (SSH was invoked before local rejection)"
    else
        record_pass "$description"
    fi
}

new_case mismatched_pub
prepare_identity
/usr/bin/ssh-keygen -q -t ed25519 -N "" -f "$case_root/wrong-key"
/bin/cp "$case_root/wrong-key.pub" "$case_home/.ssh/gpu_monitor_ed25519.pub"
expect_failure_without_ssh "mismatched existing public key fails closed"

new_case multiline_pub
prepare_identity
print 'injected-key-line' >> "$case_home/.ssh/gpu_monitor_ed25519.pub"
expect_failure_without_ssh "multiline existing public key is rejected before SSH"

new_case carriage_return_pub
prepare_identity
print -n $'\rinjected' >> "$case_home/.ssh/gpu_monitor_ed25519.pub"
expect_failure_without_ssh "carriage-return public key is rejected before SSH"

new_case invalid_pub
prepare_identity
print -r -- 'ssh-ed25519 definitely-not-valid-base64' > "$case_home/.ssh/gpu_monitor_ed25519.pub"
expect_failure_without_ssh "invalid OpenSSH public-key syntax is rejected before SSH"

new_case no_final_newline
print -n 'ssh-ed25519 unrelated-key unrelated' > "$remote_home/.ssh/authorized_keys"
if run_provisioner; then
    trusted_public_parts
    mapfile=(${(f)"$(<"$remote_home/.ssh/authorized_keys")"})
    if (( ${#mapfile} == 2 )) && [[ "$mapfile[1]" == 'ssh-ed25519 unrelated-key unrelated' && "$mapfile[2]" == "$expected_authorized_line" ]]; then
        record_pass "append preserves a missing authorized_keys line boundary"
    else
        record_failure "append preserves a missing authorized_keys line boundary"
    fi
else
    record_failure "append preserves a missing authorized_keys line boundary (provisioner failed: $(<"$stderr_log"))"
fi

new_case weak_existing_entry
prepare_identity
trusted_public_parts
print -r -- "$trusted_type $trusted_blob gpu-monitor-restricted" > "$remote_home/.ssh/authorized_keys"
before="$(<"$remote_home/.ssh/authorized_keys")"
if run_provisioner; then
    record_failure "weak existing matching blob fails closed"
elif [[ "$(<"$remote_home/.ssh/authorized_keys")" != "$before" ]]; then
    record_failure "weak existing matching blob fails closed (file changed)"
else
    record_pass "weak existing matching blob fails closed"
fi

new_case duplicate_exact_entries
prepare_identity
trusted_public_parts
{
    print -r -- "$expected_authorized_line"
    print -r -- "$expected_authorized_line"
} > "$remote_home/.ssh/authorized_keys"
if run_provisioner; then
    record_failure "duplicate matching blobs fail closed"
else
    record_pass "duplicate matching blobs fail closed"
fi

new_case tab_separated_weak_entry
prepare_identity
trusted_public_parts
print -r -- "$trusted_type"$'\t'"$trusted_blob"$'\t'"gpu-monitor-restricted" > "$remote_home/.ssh/authorized_keys"
if run_provisioner; then
    record_failure "tab-separated weak matching blob fails closed"
else
    record_pass "tab-separated weak matching blob fails closed"
fi

new_case marker_only
monitor_output=$'\n__GPU_MONITOR_PROCESSES__\n'
if run_provisioner; then
    record_failure "marker-only monitor output is rejected"
else
    record_pass "marker-only monitor output is rejected"
fi
unset monitor_output

new_case forced_marker_only
forced_output=$'\n__GPU_MONITOR_PROCESSES__\n'
if run_provisioner; then
    record_failure "marker-only forced-command output is rejected"
else
    record_pass "marker-only forced-command output is rejected"
fi
unset forced_output

new_case malformed_sample_process
monitor_output=$'0, GPU-1234, Test GPU, 0, 12, 24576, 35\n__GPU_MONITOR_PROCESSES__\nGPU-1234, not-a-pid, python, 100'
if run_provisioner; then
    record_failure "malformed sample process output is rejected"
else
    record_pass "malformed sample process output is rejected"
fi
unset monitor_output

new_case malformed_forced_process
forced_output=$'0, GPU-1234, Test GPU, 0, 12, 24576, 35\n__GPU_MONITOR_PROCESSES__\nGPU-1234, 123, , 100'
if run_provisioner; then
    record_failure "malformed forced-command process output is rejected"
else
    record_pass "malformed forced-command process output is rejected"
fi
unset forced_output

new_case nonnumeric_gpu
monitor_output=$'0, GPU-1234, Test GPU, not-a-number, 12, 24576, 35\n__GPU_MONITOR_PROCESSES__\n'
if run_provisioner; then
    record_failure "nonnumeric GPU output is rejected"
else
    record_pass "nonnumeric GPU output is rejected"
fi
unset monitor_output

new_case empty_gpu_identity
monitor_output=$'0, , Test GPU, 0, 12, 24576, 35\n__GPU_MONITOR_PROCESSES__\n'
if run_provisioner; then
    record_failure "GPU output with an empty UUID is rejected"
else
    record_pass "GPU output with an empty UUID is rejected"
fi
unset monitor_output

new_case overflowing_gpu_integer
monitor_output=$'0, GPU-1234, Test GPU, 999999999999999999999999999999, 12, 24576, 35\n__GPU_MONITOR_PROCESSES__\n'
if run_provisioner; then
    record_failure "GPU integers outside the parser range are rejected"
else
    record_pass "GPU integers outside the parser range are rejected"
fi
unset monitor_output

new_case forwarding_allowed
forward_allowed=1
if run_provisioner; then
    record_failure "successful remote forwarding fails provisioning"
else
    record_pass "successful remote forwarding fails provisioning"
fi
unset forward_allowed

new_case forwarding_unrelated_failure
forward_unrelated_failure=1
if run_provisioner; then
    record_failure "unrelated SSH forwarding failure fails closed"
else
    record_pass "unrelated SSH forwarding failure fails closed"
fi
unset forward_unrelated_failure

new_case valid_idempotent
if run_provisioner && run_provisioner; then
    trusted_public_parts
    matching_lines=$(/usr/bin/grep -Fxc -- "$expected_authorized_line" "$remote_home/.ssh/authorized_keys" || true)
    total_lines=$(/usr/bin/wc -l < "$remote_home/.ssh/authorized_keys" | /usr/bin/tr -d ' ')
    if [[ "$matching_lines" == "1" && "$total_lines" == "1" ]]; then
        record_pass "valid provisioning is idempotent"
    else
        record_failure "valid provisioning is idempotent"
    fi
else
    record_failure "valid provisioning is idempotent (provisioner failed: $(<"$stderr_log"))"
fi

if (( failures > 0 )); then
    print -u2 "$failures provisioning behavior checks failed"
    exit 1
fi

print "All provisioning behavior checks passed"
