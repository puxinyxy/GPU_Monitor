#!/bin/zsh
set -euo pipefail

[[ "${GPU_MONITOR_PROVISIONING_TESTING:-0}" == "1" ]] || exit 90
[[ -n "${GPU_MONITOR_TEST_REMOTE_HOME:-}" ]] || exit 91

{
    print -r -- '__GPU_MONITOR_SSH_CALL__'
    for argument in "$@"; do
        print -r -- "ARG:$argument"
    done
    print -r -- '__GPU_MONITOR_SSH_END__'
} >> "${GPU_MONITOR_TEST_SSH_LOG:?}"

remote_command=""
has_remote_forward=0
while (( $# > 0 )); do
    case "$1" in
        -T|-N)
            shift
            ;;
        -F|-p|-i|-o)
            (( $# >= 2 )) || exit 92
            shift 2
            ;;
        -R)
            (( $# >= 2 )) || exit 92
            has_remote_forward=1
            shift 2
            ;;
        -*)
            exit 93
            ;;
        *)
            shift
            if (( $# > 0 )); then
                remote_command="$*"
            fi
            break
            ;;
    esac
done

if (( has_remote_forward )); then
    if [[ "${GPU_MONITOR_TEST_FORWARD_UNRELATED_FAILURE:-0}" == "1" ]]; then
        if [[ "${GPU_MONITOR_TEST_FORWARD_CRLF:-0}" == "1" ]]; then
            /usr/bin/printf 'ssh: connect to host 122.207.108.8 port 10122: Connection refused\r\n' >&2
        else
            print -u2 'ssh: connect to host 122.207.108.8 port 10122: Connection refused'
        fi
        exit 255
    fi
    [[ "${GPU_MONITOR_TEST_FORWARD_ALLOWED:-0}" == "1" ]] && exit 0
    if [[ "${GPU_MONITOR_TEST_FORWARD_CRLF:-0}" == "1" ]]; then
        /usr/bin/printf 'Error: remote port forwarding failed for listen port 0\r\n' >&2
    else
        print -u2 'Error: remote port forwarding failed for listen port 0'
    fi
    exit 255
fi

if [[ "$remote_command" == *'/bin/sh -s'* ]]; then
    HOME="$GPU_MONITOR_TEST_REMOTE_HOME" /bin/sh -c "$remote_command"
    exit $?
fi

if [[ "$remote_command" == *'echo SHOULD_NOT_RUN'* ]]; then
    print -r -- "${GPU_MONITOR_TEST_FORCED_OUTPUT:-${GPU_MONITOR_TEST_MONITOR_OUTPUT:-}}"
    exit 0
fi

print -r -- "${GPU_MONITOR_TEST_MONITOR_OUTPUT:-}"
