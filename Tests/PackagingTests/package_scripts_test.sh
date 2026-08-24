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

file_text_precedes() {
    local file=$1
    local first=$2
    local second=$3
    local first_line second_line
    [[ -f "$file" ]] || return 1
    first_line=$(/usr/bin/grep -nF -- "$first" "$file" | /usr/bin/head -1)
    second_line=$(/usr/bin/grep -nF -- "$second" "$file" | /usr/bin/head -1)
    [[ -n "$first_line" && -n "$second_line" ]] || return 1
    (( ${first_line%%:*} < ${second_line%%:*} ))
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
app_entry="$project_dir/Sources/GPUMonitorApp/GPUMonitorApp.swift"
menu_view="$project_dir/Sources/GPUMonitorApp/MenuContentView.swift"
lifecycle_delegate="$project_dir/Sources/GPUMonitorApp/AppLifecycleDelegate.swift"
notification_sink="$project_dir/Sources/GPUMonitorNotifications/MacOSNotificationSink.swift"
install_behavior_test="$project_dir/Tests/PackagingTests/install_app_behavior_test.sh"
stale_first_port='102''22'

check "package script uses exact app path guard" file_contains "$package_script" '[[ "$app_dir" == "$project_dir/dist/GPU Monitor.app" ]] || exit 2'
check "package script removes only its exact bundle" file_contains "$package_script" 'rm -rf "$app_dir"'
check "package script signs ad hoc" file_contains "$package_script" 'codesign --force --deep --sign - "$app_dir"'

check "installer uses exact application destination" file_contains "$install_script" 'install_dir="/Applications/GPU Monitor.app"'
check "installer guards the application destination" file_contains "$install_script" '[[ "$install_dir" == "/Applications/GPU Monitor.app" ]] || exit 2'
check "installer removes only the guarded destination" file_contains "$install_script" 'rm -rf "$install_dir"'
check "installer does not target an Applications wildcard" file_not_contains "$install_script" '/Applications/*'
check "installer scopes process handling to the installed executable" file_contains "$install_script" 'installed_executable="$install_dir/Contents/MacOS/GPUMonitor"'
check "installer scopes process handling to the current uid" file_contains "$install_script" 'current_uid=$(/usr/bin/id -u)'
check "installer reads executable paths rather than basenames" file_contains "$install_script" '/bin/ps -axo pid=,uid=,comm='
check "installer requires an exact installed executable match" file_contains "$install_script" '"$process_executable" == "$installed_executable"'
check "installer does not use global pgrep matching" file_not_contains "$install_script" 'pgrep'
check "installer does not use global pkill matching" file_not_contains "$install_script" 'pkill'
check "installer uses the fixed bundle identifier" file_contains "$install_script" 'bundle_identifier="com.yxy.gpumonitor"'
check "installer requests graceful quit through Apple events" file_contains "$install_script" '/usr/bin/osascript'
check "installer targets graceful quit by bundle identifier" file_contains "$install_script" 'tell application id \"$bundle_identifier\" to quit'
check "installer fails closed when graceful quit fails" file_contains "$install_script" 'Unable to request a graceful GPU Monitor quit; installation stopped.'
check "installer waits for the exact process after graceful quit" file_contains "$install_script" 'The installed GPU Monitor copy did not quit gracefully; installation stopped.'
check "installer never sends SIGTERM" file_not_contains "$install_script" 'kill -TERM'
check "installer never sends SIGKILL" file_not_contains "$install_script" 'kill -KILL'
check "installer never invokes the kill utility" file_not_contains "$install_script" '/bin/kill'

check "app installs the AppKit lifecycle delegate before startup" file_contains "$app_entry" '@NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)'
check "app configures the lifecycle delegate with the live model" file_contains "$app_entry" 'lifecycleDelegate.configure(model: liveModel)'
check "lifecycle delegate defers termination" file_contains "$lifecycle_delegate" 'return .terminateLater'
check "lifecycle delegate replies only after model stop" file_text_precedes "$lifecycle_delegate" 'await model?.stop()' 'pendingReply(true)'
check "application activation refreshes authorization" file_contains "$lifecycle_delegate" 'model.refreshNotificationAuthorization()'
check "opening the menu refreshes authorization with a cancellable view task" file_contains "$menu_view" '.task { await model.refreshNotificationAuthorization() }'
check "menu quit delegates shutdown to NSApplication" file_contains "$menu_view" 'NSApplication.shared.terminate(nil)'
check "menu quit does not duplicate model shutdown" file_not_contains "$menu_view" 'await model.stop()'
check "foreground callback delegates through the tested presentation helper" file_contains "$notification_sink" 'completeForegroundPresentation(using: completionHandler)'
check "offline installer behavior harness exists" test -f "$install_behavior_test"
check "offline installer harness has a temp-root safety guard" file_contains "$install_behavior_test" 'gpu-monitor-install-test.'
check "offline installer harness traps cleanup" file_contains "$install_behavior_test" 'trap cleanup EXIT INT TERM'

forced_command='command="nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits && printf '\''\n__GPU_MONITOR_PROCESSES__\n'\'' && nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits"'
check "provisioner installs the exact forced command" file_contains "$provision_script" "$forced_command"
check "forced command never masks query failures" file_not_contains "$provision_script" '|| true"'
check "provisioner allows no command-line arguments" file_contains "$provision_script" '[[ $# -eq 0 ]]'
check "provisioner defaults to the absolute system SSH" file_contains "$provision_script" 'ssh_bin="/usr/bin/ssh"'
check "production provisioner has no environment SSH override" file_not_contains "$provision_script" 'GPU_MONITOR_TEST_SSH_BIN'
check "production provisioner has no testing flag" file_not_contains "$provision_script" 'GPU_MONITOR_PROVISIONING_TESTING'
check "provisioner ignores user SSH config" file_contains "$provision_script" '-F /dev/null'
check "provisioner fixes the SSH diagnostic locale" file_contains "$provision_script" 'LC_ALL=C'
check "provisioner derives trusted key material from the private key" file_contains "$provision_script" 'ssh-keygen -y -f "$identity_file"'
check "provisioner uses the dedicated SSH directory" file_contains "$provision_script" 'ssh_dir="$HOME/.ssh"'
check "provisioner uses the dedicated identity" file_contains "$provision_script" 'identity_file="$ssh_dir/gpu_monitor_ed25519"'
check "provisioner uses the dedicated application-support directory" file_contains "$provision_script" 'app_support_dir="$HOME/Library/Application Support/GPUMonitor"'
check "provisioner uses the dedicated known-hosts file" file_contains "$provision_script" 'known_hosts="$app_support_dir/known_hosts"'
check "provisioner quotes OpenSSH config values" file_contains "$provision_script" 'quote_openssh_config_value()'
check "provisioner builds one quoted known-hosts option" file_contains "$provision_script" 'known_hosts_option="UserKnownHostsFile=$(quote_openssh_config_value "$known_hosts")"'
check "provisioner passes the known-hosts option as one argument" file_contains "$provision_script" '-o "$known_hosts_option"'
check "provisioner never passes an unquoted config-level known-hosts value" file_not_contains "$provision_script" '-o UserKnownHostsFile="$known_hosts"'
check "provisioner covers port 10122" file_contains "$provision_script" '10122'
check "provisioner covers port 10165" file_contains "$provision_script" '10165'
check "provisioner rejects the stale first-server port" file_not_contains "$provision_script" "$stale_first_port"
check "first connection accepts only new host keys" file_contains "$provision_script" 'StrictHostKeyChecking=accept-new'
check "verification is noninteractive" file_contains "$provision_script" 'BatchMode=yes'
check "forced-command test requests a forbidden shell command" file_contains "$provision_script" 'echo SHOULD_NOT_RUN'
check "forced-command test fails on forbidden output" file_contains "$provision_script" '*SHOULD_NOT_RUN*'
check "authorized_keys installation counts exact matching lines" file_contains "$provision_script" 'exact_count'
check "authorized_keys installation counts all matching blobs" file_contains "$provision_script" 'blob_count'
check "provisioner tests remote ephemeral forwarding" file_contains "$provision_script" 'ExitOnForwardFailure=yes'
check "provisioner requests a remote ephemeral forward" file_contains "$provision_script" '-R 127.0.0.1:0:127.0.0.1:1'
check "provisioner requires the explicit OpenSSH forwarding refusal" file_contains "$provision_script" 'remote port forwarding failed for listen port 0'
check "provisioner validates full monitor output" file_contains "$provision_script" 'validate_monitor_output'
check "provisioner reports a learned fingerprint" file_contains "$provision_script" 'ssh-keygen -lf'

check "README has exact repository command" file_contains "$readme" 'cd /Users/yxy/Documents/workspace/gpu-monitor'
check "README documents the exact approved ports" file_contains "$readme" '`10122` 和 `10165`'
check "README rejects the stale first-server port" file_not_contains "$readme" "$stale_first_port"
check "README has exact provision command" file_contains "$readme" './scripts/provision_ssh.sh'
check "README has exact test command" file_contains "$readme" 'swift run GPUMonitorCoreTestsRunner'
check "README has app test command" file_contains "$readme" 'swift run GPUMonitorAppTestsRunner'
check "README has packaging policy test command" file_contains "$readme" 'zsh Tests/PackagingTests/package_scripts_test.sh'
check "README has installer behavior test command" file_contains "$readme" 'zsh Tests/PackagingTests/install_app_behavior_test.sh'
check "README has provisioning behavior test command" file_contains "$readme" 'zsh Tests/PackagingTests/provisioning_behavior_test.sh'
check "README has strict concurrency verification" file_contains "$readme" '-strict-concurrency=complete -Xswiftc -warnings-as-errors'
check "README has exact package command" file_contains "$readme" './scripts/package_app.sh'
check "README has exact install command" file_contains "$readme" './scripts/install_app.sh'
check "README documents no login-item setup" file_contains "$readme" '不配置开机自启'
check "README documents graceful installer shutdown" file_contains "$readme" 'Apple Event 请求已安装实例正常退出'
check "README documents privacy" file_contains "$readme" '隐私'
check "README documents server editing" file_contains "$readme" 'servers.json'
check "README documents config-level known-hosts quoting" file_contains "$readme" 'OpenSSH 配置值层的双引号'
check "README keeps remote-key removal explicit" file_contains "$readme" 'authorized_keys'
check "README records the public blob before deleting its file" file_text_precedes "$readme" 'awk '\''{print $2}'\'' "$HOME/.ssh/gpu_monitor_ed25519.pub"' 'rm -f "$HOME/.ssh/gpu_monitor_ed25519"'
check "README does not claim unsupported polling fields" file_not_contains "$readme" '轮询参数'

if (( failures > 0 )); then
    print -u2 "$failures packaging checks failed"
    exit 1
fi

print "All packaging checks passed"
