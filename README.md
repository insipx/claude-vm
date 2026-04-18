# claude-vm

A Nix flake that boots a headless QEMU VM with
[claude-code](https://github.com/sadjow/claude-code-nix) installed. Your current
directory is mounted into the VM at `/workspace`.

## Usage

```bash
nix run github:insipx/claude-vm
nix run github:insipx/claude-vm -- --dangerously-skip-permissions
nix run github:insipx/claude-vm -- --model sonnet
nix run github:insipx/claude-vm -- -p "fix the tests"
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

## Remote builders (host delegation)

The VM can delegate nix builds to the host machine, which then fans out to any
remote builders the host has configured (e.g. macOS builders). This uses an
ephemeral SSH keypair generated per VM session — no persistent secrets needed.

### Host prerequisites

Your host NixOS configuration needs a locked-down `builder` user:

```nix
users.users.builder = {
  isNormalUser = true;
  home = "/var/lib/builder";
  shell = pkgs.writeShellScript "nix-builder-shell" ''
    case "$SSH_ORIGINAL_COMMAND" in
      "nix-daemon --stdio") exec nix-daemon --stdio ;;
      "nix-store --serve --write") exec nix-store --serve --write ;;
      "nix-store --serve") exec nix-store --serve ;;
      *) echo "Only nix build commands allowed" >&2; exit 1 ;;
    esac
  '';
  openssh.authorizedKeys.keys = [ ]; # managed dynamically by the VM launcher
};

nix.settings.trusted-users = [ "builder" ];
```

The host must also have `sshd` running and reachable from the VM's virtual
network (QEMU routes `10.0.2.2` to the host).

The VM launcher script handles everything else automatically: generating the
ephemeral keypair, installing it in the builder's `authorized_keys` with
restrictions, and cleaning up on exit.

## Non-native users (e.g. darwin)

Make sure you have an external builder set up, or use
[Determinate Nix](https://determinate.systems) with the
[`native-linux-builder`](https://determinate.systems/blog/changelog-determinate-nix-384/)
(Page might be out of date) feature enabled, otherwise you will not be able to
build the NixOS VM.
