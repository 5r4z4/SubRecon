#!/usr/bin/env bash

# Backward-compatible entry point for users of the original release.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$SCRIPT_DIR/subdomreco.sh" "$@"
