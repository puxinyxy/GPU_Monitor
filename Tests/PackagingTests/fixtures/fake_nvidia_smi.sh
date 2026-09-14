#!/bin/zsh
set -euo pipefail

case "$*" in
    *--query-gpu=*) query_kind=gpu ;;
    *--query-compute-apps=*) query_kind=compute ;;
    *)
        print -u2 "unexpected nvidia-smi arguments"
        exit 64
        ;;
esac

invocation_kind=direct
if [[ "${GPU_MONITOR_TEST_USING_LOADER:-0}" == "1" ]]; then
    invocation_kind=loader
fi
if [[ -n "${GPU_MONITOR_TEST_NVIDIA_LOG:-}" ]]; then
    print -r -- "$invocation_kind:$query_kind" >> "$GPU_MONITOR_TEST_NVIDIA_LOG"
fi

case "$invocation_kind:$query_kind" in
    direct:gpu)
        query_status="${GPU_MONITOR_TEST_GPU_STATUS:-0}"
        [[ "$query_status" != "0" ]] || print -r -- "${GPU_MONITOR_TEST_GPU_OUTPUT:-0, GPU-test, Test GPU, 0, 0, 100, 30}"
        exit "$query_status"
        ;;
    loader:gpu)
        query_status="${GPU_MONITOR_TEST_GPU_LOADER_STATUS:-0}"
        [[ "$query_status" != "0" ]] || print -r -- "${GPU_MONITOR_TEST_GPU_LOADER_OUTPUT:-0, GPU-test-loader, Test GPU Loader, 0, 0, 100, 30}"
        exit "$query_status"
        ;;
    direct:compute)
        query_status="${GPU_MONITOR_TEST_COMPUTE_STATUS:-0}"
        if [[ "$query_status" == "0" && -n "${GPU_MONITOR_TEST_COMPUTE_OUTPUT:-}" ]]; then
            print -r -- "$GPU_MONITOR_TEST_COMPUTE_OUTPUT"
        fi
        exit "$query_status"
        ;;
    loader:compute)
        query_status="${GPU_MONITOR_TEST_COMPUTE_LOADER_STATUS:-0}"
        if [[ "$query_status" == "0" && -n "${GPU_MONITOR_TEST_COMPUTE_LOADER_OUTPUT:-}" ]]; then
            print -r -- "$GPU_MONITOR_TEST_COMPUTE_LOADER_OUTPUT"
        fi
        exit "$query_status"
        ;;
esac
