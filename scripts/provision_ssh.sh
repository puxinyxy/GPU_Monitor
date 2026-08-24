#!/bin/zsh
set -euo pipefail

[[ $# -eq 0 ]] || {
    print -u2 "Usage: ${0:t}"
    print -u2 "This script accepts no arguments and prompts through ssh when authentication is needed."
    exit 64
}

host="122.207.108.8"
username="yanxiaoyang"
ports=(10222 10165)
ssh_dir="$HOME/.ssh"
identity_file="$ssh_dir/gpu_monitor_ed25519"
public_key_file="$identity_file.pub"
app_support_dir="$HOME/Library/Application Support/GPUMonitor"
known_hosts="$app_support_dir/known_hosts"

fail() {
    print -u2 "Provisioning failed: $1"
    exit 1
}

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
if [[ ! -f "$public_key_file" ]]; then
    /usr/bin/ssh-keygen -y -f "$identity_file" > "$public_key_file"
fi
/bin/chmod 644 "$public_key_file"

if [[ ! -e "$known_hosts" ]]; then
    : > "$known_hosts"
fi
[[ -f "$known_hosts" ]] || fail "known-hosts path is not a regular file: $known_hosts"
/bin/chmod 600 "$known_hosts"

public_key="$(<"$public_key_file")"
key_type="${public_key%% *}"
key_remainder="${public_key#* }"
key_blob="${key_remainder%% *}"
[[ "$key_type" == "ssh-ed25519" && -n "$key_blob" ]] || fail "the dedicated public key is not Ed25519"

authorized_options=$(
    /bin/cat <<'OPTIONS'
no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,command="nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits; printf '\n__GPU_MONITOR_PROCESSES__\n'; nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits || true"
OPTIONS
)
authorized_line="$authorized_options $public_key"

remote_installer=$( /bin/cat <<'REMOTE_SCRIPT'
set -eu
umask 077
ssh_dir="$HOME/.ssh"
authorized_keys="$ssh_dir/authorized_keys"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
touch "$authorized_keys"
chmod 600 "$authorized_keys"
if awk -v blob="$key_blob" 'index(" " $0 " ", " " blob " ") != 0 { found = 1 } END { exit(found ? 0 : 1) }' "$authorized_keys"; then
    :
else
    printf '%s\n' "$authorized_line" >> "$authorized_keys"
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
    } | /usr/bin/ssh \
        -T \
        -p "$port" \
        -o BatchMode=no \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$known_hosts" \
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
        -i "$identity_file"
        -p "$port"
        -o BatchMode=yes
        -o IdentitiesOnly=yes
        -o StrictHostKeyChecking=yes
        -o UserKnownHostsFile="$known_hosts"
    )

    sample_output=$(/usr/bin/ssh "${ssh_options[@]}" "$destination") ||
        fail "restricted-key sample failed for port $port"
    [[ "$sample_output" == *"__GPU_MONITOR_PROCESSES__"* ]] ||
        fail "restricted-key sample omitted the expected section marker on port $port"

    forced_output=$(/usr/bin/ssh "${ssh_options[@]}" "$destination" 'echo SHOULD_NOT_RUN') ||
        fail "forced-command verification failed for port $port"
    if [[ "$forced_output" == *SHOULD_NOT_RUN* ]]; then
        fail "the requested shell command ran on port $port"
    fi
    [[ "$forced_output" == *"__GPU_MONITOR_PROCESSES__"* ]] ||
        fail "the forced command did not return monitor output on port $port"
    print "Restricted key and forced command verified for port $port."
done

print
print "SSH provisioning finished. Passwords were handled only by ssh and were not stored."
