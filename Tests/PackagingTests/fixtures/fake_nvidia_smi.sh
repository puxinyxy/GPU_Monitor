#!/bin/zsh
set -euo pipefail

case "$*" in
    *--query-gpu=*)
        print -r -- "${GPU_MONITOR_TEST_GPU_OUTPUT:-0, GPU-test, Test GPU, 0, 0, 100, 30}"
        exit "${GPU_MONITOR_TEST_GPU_STATUS:-0}"
        ;;
    *--query-compute-apps=*)
        if [[ -n "${GPU_MONITOR_TEST_COMPUTE_OUTPUT:-}" ]]; then
            print -r -- "$GPU_MONITOR_TEST_COMPUTE_OUTPUT"
        fi
        exit "${GPU_MONITOR_TEST_COMPUTE_STATUS:-0}"
        ;;
    *)
        print -u2 "unexpected nvidia-smi arguments"
        exit 64
        ;;
esac
