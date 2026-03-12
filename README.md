# claude-vm

A Nix flake that boots a headless QEMU VM with
[claude-code](https://github.com/sadjow/claude-code-nix) installed. Your current
directory is mounted into the VM at `/workspace`.

## Usage

```bash
nix run github:solomon-b/claude-vm
nix run github:solomon-b/claude-vm -- --dangerously-skip-permissions
nix run github:solomon-b/claude-vm -- --model sonnet
nix run github:solomon-b/claude-vm -- -p "fix the tests"
```

Or clone and run locally:

```bash
nix run .
```

All flags after `--` are forwarded to claude-code inside the VM.

## What's inside

- NixOS VM: 4GB RAM, 4 cores, serial console
- Packages: `claude-code`, `git`, `curl`, `vim`
- 9p shared directory: host CWD mounted read-write at `/workspace`
- Auto-login as `root` user, claude-code launches automatically

## Exit

Press `Ctrl-A X` to quit QEMU. When Claude exits normally, the VM shuts down
automatically. Run with `-c` to continue the last conversation.

## Non-native users (e.g. darwin)

Make sure you have an external builder set up, or use
[Determinate Nix](https://determinate.systems) with the
[`native-linux-builder`](https://determinate.systems/blog/changelog-determinate-nix-384/)
(Page might be out of date) feature enabled, otherwise you will not be able to
build the NixOS VM.
