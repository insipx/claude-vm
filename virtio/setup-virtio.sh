#!/usr/bin/env bash
set -euo pipefail

SOCK_DIR=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$SOCK_DIR"' EXIT

@virtiofsd@ \
  --socket-path="$SOCK_DIR/workspace.sock" \
  --shared-dir="$WORKSPACE_DIR" \
  --sandbox=none &

@virtiofsd@ \
  --socket-path="$SOCK_DIR/config.sock" \
  --shared-dir="$CLAUDE_VM_CONFIG_DIR" \
  --sandbox=none &

@virtiofsd@ \
  --socket-path="$SOCK_DIR/claude-home.sock" \
  --shared-dir="$CLAUDE_HOST_CONFIG_DIR" \
  --sandbox=none &

@virtiofsd@ \
  --socket-path="$SOCK_DIR/claude-projects.sock" \
  --shared-dir="$CLAUDE_HOST_PROJECTS_DIR" \
  --sandbox=none &

# Wait for sockets
for _i in $(seq 1 20); do
  [ -S "$SOCK_DIR/workspace.sock" ] && [ -S "$SOCK_DIR/config.sock" ] && [ -S "$SOCK_DIR/claude-home.sock" ] && [ -S "$SOCK_DIR/claude-projects.sock" ] && break
  sleep 0.1
done

export VIRTIOFSD_SOCK_DIR="$SOCK_DIR"
exec "$@"
