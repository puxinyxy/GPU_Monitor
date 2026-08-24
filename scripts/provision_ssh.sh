#!/bin/zsh
set -euo pipefail

[[ $# -eq 0 ]] || {
    print -u2 "Usage: ${0:t}"
    print -u2 "This script accepts no arguments and prompts through ssh when authentication is needed."
    exit 64
}

host="122.207.108.8"
username="yanxiaoyang"
ports=(10122 10165)
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
no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,command="nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits && printf '\n__GPU_MONITOR_PROCESSES__\n' && nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits"
OPTIONS
)
authorized_line="$authorized_options $canonical_public_key"

remote_installer=$( /bin/cat <<'REMOTE_SCRIPT'
set -eu
umask 077
ssh_dir="$HOME/.ssh"
authorized_keys="$ssh_dir/authorized_keys"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
touch "$authorized_keys"
chmod 600 "$authorized_keys"
if [ -s "$authorized_keys" ] && [ -n "$(tail -c 1 "$authorized_keys")" ]; then
    printf '\n' >> "$authorized_keys"
fi
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
exact_count=0
while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$authorized_line" ]; then
        exact_count=$((exact_count + 1))
    fi
done < "$authorized_keys"
if [ "$blob_count" -eq 0 ]; then
    printf '%s\n' "$authorized_line" >> "$authorized_keys"
elif [ "$blob_count" -eq 1 ] && [ "$exact_count" -eq 1 ]; then
    :
else
    printf '%s\n' 'Existing authorized_keys entries for this key are not uniquely and exactly restricted.' >&2
    exit 1
fi
REMOTE_SCRIPT
)

for port in $ports; do
    destination="$username@$host"
    host_token="[$host]:$port"
    print
    print "Provisioning $destination on port $port."
    print "ssh will prompt interactively for that server's login password if the key is not installed."

    {
        print -r -- "$key_blob"
        print -r -- "$authorized_line"
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
        'IFS= read -r key_blob; IFS= read -r authorized_line; export key_blob authorized_line; /bin/sh -s'

    fingerprints=$(
        /usr/bin/ssh-keygen -F "$host_token" -f "$known_hosts" 2>/dev/null |
            /usr/bin/grep -v '^#' |
            /usr/bin/ssh-keygen -lf -
    ) || fail "could not read the learned host fingerprint for port $port"
    [[ -n "$fingerprints" ]] || fail "no learned host fingerprint found for port $port"
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
        fail "restricted-key sample failed for port $port"
    validate_monitor_output "$sample_output" ||
        fail "restricted-key sample was not valid monitor output on port $port"

    forced_output=$(LC_ALL=C "$ssh_bin" "${ssh_options[@]}" "$destination" 'echo SHOULD_NOT_RUN') ||
        fail "forced-command verification failed for port $port"
    if [[ "$forced_output" == *SHOULD_NOT_RUN* ]]; then
        fail "the requested shell command ran on port $port"
    fi
    validate_monitor_output "$forced_output" ||
        fail "the forced command did not return valid monitor output on port $port"

    forwarding_stderr=""
    if forwarding_stderr=$(LC_ALL=C "$ssh_bin" "${ssh_options[@]}" \
        -o ExitOnForwardFailure=yes \
        -R 127.0.0.1:0:127.0.0.1:1 \
        "$destination" true 2>&1 >/dev/null); then
        fail "the restricted key unexpectedly allowed remote port forwarding on port $port"
    else
        forwarding_status=$?
    fi
    if (( forwarding_status != 255 )) ||
        ! print -r -- "$forwarding_stderr" |
            /usr/bin/grep -Eq '^(Error: |Warning: )?remote port forwarding failed for listen port 0$'; then
        fail "could not prove that the server explicitly rejected remote port forwarding on port $port"
    fi
    print "Restricted key and forced command verified for port $port."
done

print
print "SSH provisioning finished. Passwords were handled only by ssh and were not stored."
