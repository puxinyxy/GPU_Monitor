#!/bin/zsh
set -euo pipefail

[[ $# -eq 0 ]] || {
    print -u2 "Usage: ${0:t}"
    print -u2 "This script accepts no arguments and prompts through ssh when authentication is needed."
    exit 64
}

username="yanxiaoyang"
endpoint_specs=(
    "122.207.108.8 10122"
    "122.207.108.7 10165"
    "js2.blockelite.cn 18200"
    "js2.blockelite.cn 13000"
)
ssh_dir="$HOME/.ssh"
identity_file="$ssh_dir/gpu_monitor_ed25519"
public_key_file="$identity_file.pub"
app_support_dir="$HOME/Library/Application Support/GPUMonitor"
known_hosts="$app_support_dir/known_hosts"

fail() {
    print -u2 "Provisioning failed: $1"
    exit 1
}

is_parser_integer() {
    local digits=$1
    local maximum="9223372036854775807"
    if [[ "$digits[1]" == "-" ]]; then
        digits="${digits[2,-1]}"
        maximum="9223372036854775808"
    elif [[ "$digits[1]" == "+" ]]; then
        digits="${digits[2,-1]}"
    fi
    [[ "$digits" == <-> ]] || return 1
    while (( ${#digits} > 1 )) && [[ "$digits[1]" == "0" ]]; do
        digits="${digits[2,-1]}"
    done
    (( ${#digits} < ${#maximum} )) && return 0
    (( ${#digits} == ${#maximum} )) || return 1
    [[ "$digits" == "$maximum" || "$digits" < "$maximum" ]]
}

validate_monitor_output() {
    local output=$1
    local marker_count=0
    local gpu_count=0
    local before_marker=1
    local line trimmed field
    local process_line
    local -a fields process_lines

    for line in "${(@f)output}"; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [[ -n "$trimmed" ]] || continue
        if [[ "$trimmed" == "__GPU_MONITOR_PROCESSES__" ]]; then
            marker_count=$((marker_count + 1))
            before_marker=0
            continue
        fi
        if (( before_marker )); then
            fields=("${(@s:,:)trimmed}")
            (( ${#fields} == 7 )) || return 1
            for field in {1..7}; do
                fields[$field]="${fields[$field]#"${fields[$field]%%[![:space:]]*}"}"
                fields[$field]="${fields[$field]%"${fields[$field]##*[![:space:]]}"}"
            done
            [[ -n "$fields[2]" && -n "$fields[3]" ]] || return 1
            is_parser_integer "$fields[1]" || return 1
            for field in 4 5 6 7; do
                is_parser_integer "$fields[$field]" || return 1
            done
            gpu_count=$((gpu_count + 1))
        else
            process_lines+=("$trimmed")
        fi
    done

    (( marker_count == 1 && gpu_count > 0 )) || return 1
    (( ${#process_lines} == 0 )) && return 0
    if (( ${#process_lines} == 1 )) && [[ "$process_lines[1]" == "No running processes found" ]]; then
        return 0
    fi

    for process_line in "${process_lines[@]}"; do
        fields=("${(@s:,:)process_line}")
        (( ${#fields} == 4 )) || return 1
        for field in {1..4}; do
            fields[$field]="${fields[$field]#"${fields[$field]%%[![:space:]]*}"}"
            fields[$field]="${fields[$field]%"${fields[$field]##*[![:space:]]}"}"
        done
        [[ -n "$fields[1]" && -n "$fields[3]" ]] || return 1
        is_parser_integer "$fields[2]" || return 1
        is_parser_integer "$fields[4]" || return 1
    done
}

quote_openssh_config_value() {
    local value=$1
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    print -r -- "\"$value\""
}

ssh_bin="/usr/bin/ssh"

umask 077
/bin/mkdir -p "$ssh_dir" "$app_support_dir"
/bin/chmod 700 "$ssh_dir"

if [[ ! -e "$identity_file" ]]; then
    [[ ! -e "$public_key_file" ]] || fail "public key exists without its private key: $public_key_file"
    print "Creating dedicated GPU Monitor SSH identity: $identity_file"
    /usr/bin/ssh-keygen -q -t ed25519 -N "" -C "gpu-monitor-restricted" -f "$identity_file"
fi

[[ -f "$identity_file" ]] || fail "identity is not a regular file: $identity_file"
/bin/chmod 600 "$identity_file"

derived_public_key=$(/usr/bin/ssh-keygen -y -f "$identity_file") || fail "could not derive the public key from the private key"
if [[ "$derived_public_key" == *$'\n'* || "$derived_public_key" == *$'\r'* ]] ||
    ! print -r -- "$derived_public_key" | /usr/bin/ssh-keygen -lf - >/dev/null 2>&1; then
    fail "the private key produced invalid OpenSSH public-key syntax"
fi
key_type="${derived_public_key%% *}"
derived_remainder="${derived_public_key#* }"
key_blob="${derived_remainder%% *}"
[[ "$key_type" == "ssh-ed25519" && -n "$key_blob" ]] ||
    fail "the dedicated private key did not produce an Ed25519 public key"

if [[ -e "$public_key_file" ]]; then
    [[ -f "$public_key_file" ]] || fail "public-key path is not a regular file: $public_key_file"
    /usr/bin/awk '
        index($0, "\r") != 0 || NR > 1 { invalid = 1 }
        END { exit(NR == 1 && !invalid ? 0 : 1) }
    ' "$public_key_file" || fail "the existing public-key file is not exactly one OpenSSH line"
    /usr/bin/ssh-keygen -lf "$public_key_file" >/dev/null 2>&1 ||
        fail "the existing public-key file has invalid OpenSSH syntax"
    existing_public_key="$(<"$public_key_file")"
    existing_type="${existing_public_key%% *}"
    existing_remainder="${existing_public_key#* }"
    existing_blob="${existing_remainder%% *}"
    [[ "$existing_type" == "$key_type" && "$existing_blob" == "$key_blob" ]] ||
        fail "the existing public key does not match the dedicated private key"
fi

canonical_public_key="$key_type $key_blob gpu-monitor-restricted"
print -r -- "$canonical_public_key" > "$public_key_file"
/bin/chmod 644 "$public_key_file"

if [[ ! -e "$known_hosts" ]]; then
    : > "$known_hosts"
fi
[[ -f "$known_hosts" ]] || fail "known-hosts path is not a regular file: $known_hosts"
/bin/chmod 600 "$known_hosts"
known_hosts_option="UserKnownHostsFile=$(quote_openssh_config_value "$known_hosts")"

authorized_options=$(
    /bin/cat <<'OPTIONS'
no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,command="{ /usr/bin/nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits; nvidia_status=$?; if [ $nvidia_status -eq 127 ]; then /lib64/ld-linux-x86-64.so.2 /usr/bin/nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits; else (exit $nvidia_status); fi; } && printf '\n__GPU_MONITOR_PROCESSES__\n' && { /usr/bin/nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits; nvidia_status=$?; if [ $nvidia_status -eq 127 ]; then /lib64/ld-linux-x86-64.so.2 /usr/bin/nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits; else (exit $nvidia_status); fi; }"
OPTIONS
)
legacy_authorized_options=$(
    /bin/cat <<'OPTIONS'
no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,command="nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits && printf '\n__GPU_MONITOR_PROCESSES__\n' && nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits"
OPTIONS
)
authorized_line="$authorized_options $canonical_public_key"
legacy_authorized_line="$legacy_authorized_options $canonical_public_key"
[[ "$authorized_line" != "$legacy_authorized_line" ]] || fail "the restricted-key migration definitions unexpectedly match"

remote_installer=$( /bin/cat <<'REMOTE_SCRIPT'
set -eu
umask 077
ssh_dir="$HOME/.ssh"
authorized_keys="$ssh_dir/authorized_keys"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
touch "$authorized_keys"
chmod 600 "$authorized_keys"
blob_count=$(awk -v blob="$key_blob" '
    {
        for (field = 1; field <= NF; field++) {
            if ($field == blob) {
                count++
                break
            }
        }
    }
    END { print count + 0 }
' "$authorized_keys")
new_exact_count=0
legacy_exact_count=0
while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$authorized_line" ]; then
        new_exact_count=$((new_exact_count + 1))
    fi
    if [ "$line" = "$legacy_authorized_line" ]; then
        legacy_exact_count=$((legacy_exact_count + 1))
    fi
done < "$authorized_keys"
if [ "$blob_count" -eq 0 ]; then
    if [ -s "$authorized_keys" ] && [ -n "$(tail -c 1 "$authorized_keys")" ]; then
        printf '\n' >> "$authorized_keys"
    fi
    printf '%s\n' "$authorized_line" >> "$authorized_keys"
    printf '%s\n' 'newly-installed'
elif [ "$blob_count" -eq 1 ] && [ "$new_exact_count" -eq 1 ] && [ "$legacy_exact_count" -eq 0 ]; then
    printf '%s\n' 'already-present'
elif [ "$blob_count" -eq 1 ] && [ "$new_exact_count" -eq 0 ] && [ "$legacy_exact_count" -eq 1 ]; then
    migration_file=$(mktemp "$ssh_dir/.gpu-monitor-authorized-keys-migrate.XXXXXX") || exit 1
    trap 'rm -f "$migration_file"' EXIT HUP INT TERM
    replaced=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$replaced" -eq 0 ] && [ "$line" = "$legacy_authorized_line" ]; then
            printf '%s\n' "$authorized_line" >> "$migration_file"
            replaced=1
        else
            printf '%s\n' "$line" >> "$migration_file"
        fi
    done < "$authorized_keys"
    [ "$replaced" -eq 1 ] || exit 1

    candidate_blob_count=$(awk -v blob="$key_blob" '
        {
            for (field = 1; field <= NF; field++) {
                if ($field == blob) {
                    count++
                    break
                }
            }
        }
        END { print count + 0 }
    ' "$migration_file")
    candidate_new_exact_count=0
    candidate_legacy_exact_count=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$authorized_line" ]; then
            candidate_new_exact_count=$((candidate_new_exact_count + 1))
        fi
        if [ "$line" = "$legacy_authorized_line" ]; then
            candidate_legacy_exact_count=$((candidate_legacy_exact_count + 1))
        fi
    done < "$migration_file"
    [ "$candidate_blob_count" -eq 1 ] &&
        [ "$candidate_new_exact_count" -eq 1 ] &&
        [ "$candidate_legacy_exact_count" -eq 0 ] || exit 1
    chmod 600 "$migration_file"
    mv "$migration_file" "$authorized_keys"
    trap - EXIT HUP INT TERM
    printf '%s\n' 'migrated'
else
    printf '%s\n' 'Existing authorized_keys entries for this key are not uniquely and exactly restricted.' >&2
    exit 1
fi
REMOTE_SCRIPT
)

remote_rollback=$( /bin/cat <<'REMOTE_SCRIPT'
set -eu
umask 077
ssh_dir="$HOME/.ssh"
authorized_keys="$ssh_dir/authorized_keys"
[ -f "$authorized_keys" ] || exit 1
case "$rollback_action" in
    remove-new|restore-legacy) ;;
    *) exit 1 ;;
esac
blob_count=$(awk -v blob="$key_blob" '
    {
        for (field = 1; field <= NF; field++) {
            if ($field == blob) {
                count++
                break
            }
        }
    }
    END { print count + 0 }
' "$authorized_keys")
new_exact_count=0
legacy_exact_count=0
while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$authorized_line" ]; then
        new_exact_count=$((new_exact_count + 1))
    fi
    if [ "$line" = "$legacy_authorized_line" ]; then
        legacy_exact_count=$((legacy_exact_count + 1))
    fi
done < "$authorized_keys"
[ "$blob_count" -eq 1 ] &&
    [ "$new_exact_count" -eq 1 ] &&
    [ "$legacy_exact_count" -eq 0 ] || exit 1

rollback_file=$(mktemp "$ssh_dir/.gpu-monitor-authorized-keys-rollback.XXXXXX") || exit 1
trap 'rm -f "$rollback_file"' EXIT HUP INT TERM
removed=0
while IFS= read -r line || [ -n "$line" ]; do
    if [ "$removed" -eq 0 ] && [ "$line" = "$authorized_line" ]; then
        removed=1
        if [ "$rollback_action" = "restore-legacy" ]; then
            printf '%s\n' "$legacy_authorized_line" >> "$rollback_file"
        fi
        continue
    fi
    printf '%s\n' "$line" >> "$rollback_file"
done < "$authorized_keys"
[ "$removed" -eq 1 ] || exit 1
candidate_blob_count=$(awk -v blob="$key_blob" '
    {
        for (field = 1; field <= NF; field++) {
            if ($field == blob) {
                count++
                break
            }
        }
    }
    END { print count + 0 }
' "$rollback_file")
candidate_new_exact_count=0
candidate_legacy_exact_count=0
while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$authorized_line" ]; then
        candidate_new_exact_count=$((candidate_new_exact_count + 1))
    fi
    if [ "$line" = "$legacy_authorized_line" ]; then
        candidate_legacy_exact_count=$((candidate_legacy_exact_count + 1))
    fi
done < "$rollback_file"
[ "$candidate_new_exact_count" -eq 0 ] || exit 1
if [ "$rollback_action" = "remove-new" ]; then
    [ "$candidate_blob_count" -eq 0 ] && [ "$candidate_legacy_exact_count" -eq 0 ] || exit 1
else
    [ "$candidate_blob_count" -eq 1 ] && [ "$candidate_legacy_exact_count" -eq 1 ] || exit 1
fi
chmod 600 "$rollback_file"
mv "$rollback_file" "$authorized_keys"
trap - EXIT HUP INT TERM
printf '%s\n' 'rolled-back'
REMOTE_SCRIPT
)

rollback_restricted_key() {
    local port=$1
    local destination=$2
    local rollback_action=$3
    local rollback_status

    rollback_status=$({
        print -r -- "$key_blob"
        print -r -- "$authorized_line"
        print -r -- "$legacy_authorized_line"
        print -r -- "$rollback_action"
        print -r -- "$remote_rollback"
    } | LC_ALL=C "$ssh_bin" \
        -T \
        -F /dev/null \
        -p "$port" \
        -o BatchMode=no \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o StrictHostKeyChecking=yes \
        -o "$known_hosts_option" \
        "$destination" \
        'IFS= read -r key_blob; IFS= read -r authorized_line; IFS= read -r legacy_authorized_line; IFS= read -r rollback_action; export key_blob authorized_line legacy_authorized_line rollback_action; /bin/sh -s -- rollback') || return 1
    [[ "$rollback_status" == "rolled-back" ]]
}

fail_after_verification() {
    local message=$1
    local port=$2
    local destination=$3
    local rollback_action=$4

    if [[ "$rollback_action" != "none" ]]; then
        if [[ "$rollback_action" == "remove-new" ]]; then
            print -u2 "Security verification failed for port $port; rolling back the newly installed restricted key."
        else
            print -u2 "Security verification failed for port $port; restoring the previous exact restricted key."
        fi
        if ! rollback_restricted_key "$port" "$destination" "$rollback_action"; then
            print -u2 "Provisioning failed: $message"
            if [[ "$rollback_action" == "remove-new" ]]; then
                print -u2 "Automatic rollback failed for port $port. Manual remediation required: remove the GPU Monitor restricted authorized_keys entry on that server before retrying."
            else
                print -u2 "Automatic rollback failed for port $port. Manual remediation required: restore the prior exact GPU Monitor restricted authorized_keys entry on that server before retrying."
            fi
            exit 1
        fi
    fi
    fail "$message"
}

for endpoint_spec in "${endpoint_specs[@]}"; do
    host="${endpoint_spec%% *}"
    port="${endpoint_spec##* }"
    destination="$username@$host"
    host_token="[$host]:$port"
    print
    print "Provisioning $destination on port $port."
    print "ssh will prompt interactively for that server's login password if the key is not installed."

    installation_status=$({
        print -r -- "$key_blob"
        print -r -- "$authorized_line"
        print -r -- "$legacy_authorized_line"
        print -r -- "$remote_installer"
    } | LC_ALL=C "$ssh_bin" \
        -T \
        -F /dev/null \
        -p "$port" \
        -o BatchMode=no \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o StrictHostKeyChecking=accept-new \
        -o "$known_hosts_option" \
        "$destination" \
        'IFS= read -r key_blob; IFS= read -r authorized_line; IFS= read -r legacy_authorized_line; export key_blob authorized_line legacy_authorized_line; /bin/sh -s') ||
        fail "could not install the restricted key for port $port"
    case "$installation_status" in
        newly-installed) rollback_action=remove-new ;;
        migrated) rollback_action=restore-legacy ;;
        already-present) rollback_action=none ;;
        *) fail "the remote key installation result was invalid for port $port" ;;
    esac

    fingerprints=$(
        /usr/bin/ssh-keygen -F "$host_token" -f "$known_hosts" 2>/dev/null |
            /usr/bin/grep -v '^#' |
            /usr/bin/ssh-keygen -lf -
    ) || fail_after_verification \
        "could not read the learned host fingerprint for port $port" \
        "$port" "$destination" "$rollback_action"
    [[ -n "$fingerprints" ]] || fail_after_verification \
        "no learned host fingerprint found for port $port" \
        "$port" "$destination" "$rollback_action"
    print "Learned host fingerprint for $host_token:"
    print -r -- "$fingerprints"

    ssh_options=(
        -T
        -F /dev/null
        -i "$identity_file"
        -p "$port"
        -o BatchMode=yes
        -o IdentitiesOnly=yes
        -o StrictHostKeyChecking=yes
        -o "$known_hosts_option"
    )

    sample_output=$(LC_ALL=C "$ssh_bin" "${ssh_options[@]}" "$destination") ||
        fail_after_verification "restricted-key sample failed for port $port" \
            "$port" "$destination" "$rollback_action"
    validate_monitor_output "$sample_output" ||
        fail_after_verification \
            "restricted-key sample was not valid monitor output on port $port" \
            "$port" "$destination" "$rollback_action"

    forced_output=$(LC_ALL=C "$ssh_bin" "${ssh_options[@]}" "$destination" 'echo SHOULD_NOT_RUN') ||
        fail_after_verification "forced-command verification failed for port $port" \
            "$port" "$destination" "$rollback_action"
    if [[ "$forced_output" == *SHOULD_NOT_RUN* ]]; then
        fail_after_verification "the requested shell command ran on port $port" \
            "$port" "$destination" "$rollback_action"
    fi
    validate_monitor_output "$forced_output" ||
        fail_after_verification \
            "the forced command did not return valid monitor output on port $port" \
            "$port" "$destination" "$rollback_action"

    forwarding_stderr=""
    if forwarding_stderr=$(LC_ALL=C "$ssh_bin" "${ssh_options[@]}" \
        -o ExitOnForwardFailure=yes \
        -R 127.0.0.1:0:127.0.0.1:1 \
        "$destination" true 2>&1 >/dev/null); then
        fail_after_verification \
            "the restricted key unexpectedly allowed remote port forwarding on port $port" \
            "$port" "$destination" "$rollback_action"
    else
        forwarding_status=$?
    fi
    forwarding_stderr="${forwarding_stderr%$'\r'}"
    if (( forwarding_status != 255 )); then
        fail_after_verification \
            "could not prove that the server explicitly rejected remote port forwarding on port $port" \
            "$port" "$destination" "$rollback_action"
    fi
    case "$forwarding_stderr" in
        'remote port forwarding failed for listen port 0'|'Error: remote port forwarding failed for listen port 0'|'Warning: remote port forwarding failed for listen port 0')
            ;;
        *)
            fail_after_verification \
                "could not prove that the server explicitly rejected remote port forwarding on port $port" \
                "$port" "$destination" "$rollback_action"
            ;;
    esac

    final_output=$(LC_ALL=C "$ssh_bin" "${ssh_options[@]}" "$destination") ||
        fail_after_verification "final restricted-key validation failed for port $port" \
            "$port" "$destination" "$rollback_action"
    validate_monitor_output "$final_output" ||
        fail_after_verification \
            "final restricted-key validation was not valid monitor output on port $port" \
            "$port" "$destination" "$rollback_action"
    print "Restricted key and forced command verified for port $port."
done

print
print "SSH provisioning finished. Passwords were handled only by ssh and were not stored."
