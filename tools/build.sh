#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ddk_bin="${DDK:-ddk}"
ddk_bin=$(command -v -- "$ddk_bin")

cd "$root_dir"
"$ddk_bin" build android16-6.12 -- -j"$(nproc)"
"$root_dir/tools/verify-artifacts.sh"

