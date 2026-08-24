#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h:h}
failures=0

check() {
    local description=$1
    shift
    if "$@"; then
        print "PASS: $description"
    else
        print -u2 "FAIL: $description"
        failures=$((failures + 1))
    fi
}

file_contains() {
    local file=$1
    local needle=$2
    [[ -f "$file" ]] && /usr/bin/grep -Fq -- "$needle" "$file"
}

file_not_contains() {
    local file=$1
    local needle=$2
    [[ -f "$file" ]] && ! /usr/bin/grep -Fiq -- "$needle" "$file"
}

plist_value_is() {
    local key=$1
    local expected=$2
    [[ -f "$project_dir/packaging/Info.plist" ]] &&
        [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$project_dir/packaging/Info.plist" 2>/dev/null)" == "$expected" ]]
}

check "Info.plist exists" test -f "$project_dir/packaging/Info.plist"
check "bundle identifier is fixed" plist_value_is CFBundleIdentifier com.yxy.gpumonitor
check "bundle executable is fixed" plist_value_is CFBundleExecutable GPUMonitor
check "bundle name is fixed" plist_value_is CFBundleName "GPU Monitor"
check "display name is fixed" plist_value_is CFBundleDisplayName "GPU Monitor"
check "bundle type is APPL" plist_value_is CFBundlePackageType APPL
check "short version is 1.0.0" plist_value_is CFBundleShortVersionString 1.0.0
check "build version is 1" plist_value_is CFBundleVersion 1
check "minimum macOS is 14.0" plist_value_is LSMinimumSystemVersion 14.0
check "app is a UI element" plist_value_is LSUIElement true
check "high resolution is enabled" plist_value_is NSHighResolutionCapable true

package_script="$project_dir/scripts/package_app.sh"
install_script="$project_dir/scripts/install_app.sh"
provision_script="$project_dir/scripts/provision_ssh.sh"
readme="$project_dir/README.md"

check "package script uses exact app path guard" file_contains "$package_script" '[[ "$app_dir" == "$project_dir/dist/GPU Monitor.app" ]] || exit 2'
check "package script removes only its exact bundle" file_contains "$package_script" 'rm -rf "$app_dir"'
check "package script signs ad hoc" file_contains "$package_script" 'codesign --force --deep --sign - "$app_dir"'

check "installer uses exact application destination" file_contains "$install_script" 'install_dir="/Applications/GPU Monitor.app"'
check "installer guards the application destination" file_contains "$install_script" '[[ "$install_dir" == "/Applications/GPU Monitor.app" ]] || exit 2'
check "installer removes only the guarded destination" file_contains "$install_script" 'rm -rf "$install_dir"'
check "installer does not target an Applications wildcard" file_not_contains "$install_script" '/Applications/*'

forced_command='command="nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits; printf '\''\n__GPU_MONITOR_PROCESSES__\n'\''; nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits || true"'
check "provisioner installs the exact forced command" file_contains "$provision_script" "$forced_command"
check "provisioner allows no command-line arguments" file_contains "$provision_script" '[[ $# -eq 0 ]]'
check "provisioner uses the dedicated SSH directory" file_contains "$provision_script" 'ssh_dir="$HOME/.ssh"'
check "provisioner uses the dedicated identity" file_contains "$provision_script" 'identity_file="$ssh_dir/gpu_monitor_ed25519"'
check "provisioner uses the dedicated application-support directory" file_contains "$provision_script" 'app_support_dir="$HOME/Library/Application Support/GPUMonitor"'
check "provisioner uses the dedicated known-hosts file" file_contains "$provision_script" 'known_hosts="$app_support_dir/known_hosts"'
check "provisioner covers port 10222" file_contains "$provision_script" '10222'
check "provisioner covers port 10165" file_contains "$provision_script" '10165'
check "first connection accepts only new host keys" file_contains "$provision_script" 'StrictHostKeyChecking=accept-new'
check "verification is noninteractive" file_contains "$provision_script" 'BatchMode=yes'
check "forced-command test requests a forbidden shell command" file_contains "$provision_script" 'echo SHOULD_NOT_RUN'
check "forced-command test fails on forbidden output" file_contains "$provision_script" '*SHOULD_NOT_RUN*'
check "authorized_keys installation searches for the public-key blob" file_contains "$provision_script" 'key_blob'
check "provisioner reports a learned fingerprint" file_contains "$provision_script" 'ssh-keygen -lf'

check "README has exact repository command" file_contains "$readme" 'cd /Users/yxy/Documents/workspace/gpu-monitor'
check "README has exact provision command" file_contains "$readme" './scripts/provision_ssh.sh'
check "README has exact test command" file_contains "$readme" 'swift run GPUMonitorCoreTestsRunner'
check "README has exact package command" file_contains "$readme" './scripts/package_app.sh'
check "README has exact install command" file_contains "$readme" './scripts/install_app.sh'
check "README documents no login-item setup" file_contains "$readme" '不配置开机自启'
check "README documents privacy" file_contains "$readme" '隐私'
check "README documents server editing" file_contains "$readme" 'servers.json'
check "README keeps remote-key removal explicit" file_contains "$readme" 'authorized_keys'

if (( failures > 0 )); then
    print -u2 "$failures packaging checks failed"
    exit 1
fi

print "All packaging checks passed"
