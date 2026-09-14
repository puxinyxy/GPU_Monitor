#!/bin/zsh
set -euo pipefail

(( $# >= 1 )) || exit 64
target=$1
shift

GPU_MONITOR_TEST_USING_LOADER=1 "$target" "$@"
