#!/usr/bin/env bash
# Regenerate Go code from the proto definitions.
# Prefers buf (CI standard); falls back to raw protoc for local dev.
set -euo pipefail
cd "$(dirname "$0")"

if command -v buf >/dev/null 2>&1; then
  buf lint
  buf generate
else
  echo "buf not found; falling back to protoc" >&2
  protoc \
    --go_out=gen/go --go_opt=paths=source_relative \
    --go-grpc_out=gen/go --go-grpc_opt=paths=source_relative \
    flock/types/v1/types.proto \
    flock/tunnel/v1/tunnel.proto \
    flock/control/v1/control.proto
fi
echo "generated into gen/go/"
