{
  description = "Headless QEMU VM with claude-code — nix run . -- <flags>";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
    jujutsu = {
      url = "github:jj-vcs/jj/v0.38.0";
      # url = "github:jj-vcs/jj";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    import-tree.url = "github:vic/import-tree";
    flake-parts.url = "github:hercules-ci/flake-parts";
    jupiter-secrets = {
      url = "github:insipx/jupiter-secrets";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      claude-code-nix,
      ...
    }:
    let
      supportedSystems = [
        "aarch64-linux"
        "x86_64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # aarch64-darwin -> aarch64-linux, x86_64-darwin -> x86_64-linux
      guestSystemFor = hostSystem: builtins.replaceStrings [ "darwin" ] [ "linux" ] hostSystem;

      mkVM =
        hostSystem:
        let
          guestSystem = guestSystemFor hostSystem;
          hostPkgs = import nixpkgs {
            system = hostSystem;
            overlays = [
              inputs.jujutsu.overlays.default
              inputs.jupiter-secrets.overlays.default
            ];
          };
        in
        {
          inherit hostPkgs;
          nixosSystem = nixpkgs.lib.nixosSystem {
            system = guestSystem;
            modules = [
              inputs.jupiter-secrets.nixosModules.default
              (
                {
                  pkgs,
                  modulesPath,
                  config,
                  ...
                }:
                {
                  imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];
                  # ---------- host / guest plumbing ----------
                  virtualisation = {
                    cores = 4;
                    graphics = false;
                    host = {
                      pkgs = hostPkgs;
                    };
                    memorySize = 16384;
                    diskSize = 65536;
                    writableStoreUseTmpfs = false;
                    qemu.options = [
                      "-object"
                      "memory-backend-memfd,id=mem,size=16384M,share=on"
                      "-machine"
                      "memory-backend=mem"
                      # workspace
                      "-chardev"
                      ''socket,id=char-workspace,path="$VIRTIOFSD_SOCK_DIR"/workspace.sock''
                      "-device"
                      "vhost-user-fs-pci,chardev=char-workspace,tag=workspace"
                      # config
                      "-chardev"
                      ''socket,id=char-config,path="$VIRTIOFSD_SOCK_DIR"/config.sock''
                      "-device"
                      "vhost-user-fs-pci,chardev=char-config,tag=config"
                      # host ~/.claude (read-only bind)
                      "-chardev"
                      ''socket,id=char-claude-home,path="$VIRTIOFSD_SOCK_DIR"/claude-home.sock''
                      "-device"
                      "vhost-user-fs-pci,chardev=char-claude-home,tag=claude-home"
                    ];
                  };

                  # ---------- boot / console ----------
                  # Replace the boot block:
                  boot = {
                    kernelParams = [ "console=ttyS0" ];
                    loader.grub.enable = false;
                    initrd.availableKernelModules = [ "virtiofs" ];
                  };
                  # virtiofs mounts — must go under virtualisation.fileSystems
                  # because qemu-vm.nix overrides top-level fileSystems
                  virtualisation.fileSystems."/workspace" = {
                    device = "workspace";
                    fsType = "virtiofs";
                    neededForBoot = true;
                  };

                  virtualisation.fileSystems."/mnt/claude-vm-config" = {
                    device = "config";
                    fsType = "virtiofs";
                    neededForBoot = true;
                  };

                  # Host ~/.claude mounted read-only at /root/.claude
                  virtualisation.fileSystems."/root/.claude" = {
                    device = "claude-home";
                    fsType = "virtiofs";
                    options = [ "ro" ];
                  };

                  # Writable tmpfs for VM-local conversation history (overlays the ro mount)
                  virtualisation.fileSystems."/root/.claude/projects" = {
                    device = "tmpfs";
                    fsType = "tmpfs";
                    options = [
                      "nosuid"
                      "nodev"
                      "mode=755"
                    ];
                  };

                  services.getty.autologinUser = "root";

                  # ---------- packages ----------
                  nixpkgs = {
                    config.allowUnfree = true;
                    overlays = [ claude-code-nix.overlays.default ];
                  };
                  networking.useDHCP = true;
                  environment.systemPackages = with pkgs; [
                    claude-code
                    git
                    curl
                    vim
                    jujutsu
                    gh
                    nix-output-monitor
                  ];
                  programs.direnv = {
                    enable = true;
                    nix-direnv.enable = true;
                    enableBashIntegration = true;
                  };
                  programs.git = {
                    enable = true;
                    config = {
                      user.name = "Andrew Plaza";
                      user.email = "github@andrewplaza.dev";
                      url."https://github.com/".insteadOf = "git@github.com:";
                      credential."https://github.com".helper =
                        "!f() { echo \"protocol=https\nhost=github.com\nusername=x-access-token\npassword=\$GH_TOKEN\"; }; f";
                    };
                  };
                  # ---------- remote builder (host delegation) ----------
                  system.activationScripts.builder-ssh = ''
                                        if [ -f /mnt/claude-vm-config/builder-ssh-key ]; then
                                          mkdir -p /root/.ssh
                                          cp /mnt/claude-vm-config/builder-ssh-key /root/.ssh/builder_key
                                          chmod 600 /root/.ssh/builder_key

                                          # Trust the host's SSH key
                                          if [ -f /mnt/claude-vm-config/host-ssh-pubkey ]; then
                                            HOSTKEY=$(cat /mnt/claude-vm-config/host-ssh-pubkey)
                                            echo "10.0.2.2 $HOSTKEY" > /root/.ssh/known_hosts
                                            chmod 644 /root/.ssh/known_hosts
                                          fi

                                          # SSH config so substituter and buildMachines can find the key
                                          cat > /root/.ssh/config <<'SSHEOF'
                    Host 10.0.2.2
                      User builder
                      IdentityFile /root/.ssh/builder_key
                      IdentitiesOnly yes
                    SSHEOF
                                          chmod 600 /root/.ssh/config
                                        fi
                  '';
                  nix.buildMachines = [
                    {
                      hostName = "10.0.2.2";
                      sshUser = "builder";
                      sshKey = "/root/.ssh/builder_key";
                      systems = [
                        "x86_64-linux"
                        "aarch64-linux"
                        "x86_64-darwin"
                        "aarch64-darwin"
                      ];
                      maxJobs = 100;
                      supportedFeatures = [
                        "nixos-test"
                        "big-parallel"
                        "kvm"
                      ];
                      protocol = "ssh-ng";
                    }
                  ];
                  nix.distributedBuilds = true;

                  # ---------- nix flakes in guest ----------
                  nix.settings = {
                    experimental-features = [
                      "nix-command"
                      "flakes"
                    ];
                    substituters = [
                      "ssh://builder@10.0.2.2"
                      "https://xmtp.cachix.org"
                      "https://nix-community.cachix.org"
                    ];
                    trusted-public-keys = [
                      "xmtp.cachix.org-1:nFPFrqLQ9kjYQKiWL7gKq6llcNEeaV4iI+Ka1F+Tmq0="
                      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
                    ];
                    # Auto-GC when free disk drops below 1GB, free up to 5GB
                    min-free = "${toString (1024 * 1024 * 1024)}";
                    max-free = "${toString (20 * 1024 * 1024 * 1024)}";
                  };
                  nix.gc = {
                    automatic = true;
                    dates = "hourly";
                    options = "--delete-older-than 1h";
                  };
                  environment.variables = {
                    IS_SANDBOX = 1;
                    CARGO_TARGET_DIR = "/tmp/cargo-target";
                  };
                  # ---------- login shell launches claude ----------
                  programs.bash.interactiveShellInit = ''
                    [ "$(whoami)" = "root" ] || return

                    args=()
                    if [ -f /mnt/claude-vm-config/claude-args ]; then
                      while IFS= read -r line; do
                        [ -n "$line" ] && args+=("$line")
                      done < /mnt/claude-vm-config/claude-args
                    fi

                    # Export GitHub token for gh CLI and git credential helper
                    if [ -f /mnt/claude-vm-config/gh-token ]; then
                      export GH_TOKEN=$(cat /mnt/claude-vm-config/gh-token)
                      export GITHUB_TOKEN="$GH_TOKEN"
                    fi
                    cd /workspace 2>/dev/null || true
                    claude "''${args[@]}"
                    EXIT_CODE=$?
                    echo "=== claude exited with code $EXIT_CODE ==="
                    systemctl poweroff -f
                  '';

                  # ---------- misc ----------
                  networking.hostName = "claude-vm";
                  system.stateVersion = "25.05";
                }
              )
            ];
          };
        };
    in
    {
      packages = forAllSystems (
        hostSystem:
        let
          vm = mkVM hostSystem;
          vmBuild = vm.nixosSystem.config.system.build.vm;
          setupVirtio = vm.hostPkgs.callPackage ./virtio { };
        in
        {
          default = vm.hostPkgs.writeShellScriptBin "claude-vm" ''
            CONFIG_DIR=$(mktemp -d)

            # Write all CLI args to a file, one per line
            if [ $# -gt 0 ]; then
              printf '%s\n' "$@" > "$CONFIG_DIR/claude-args"
            else
              touch "$CONFIG_DIR/claude-args"
            fi

            # Resolve GitHub token: explicit env var > gh CLI > skip
            GH_TOKEN="''${GH_TOKEN:-''${GITHUB_TOKEN:-}}"
            if [ -z "$GH_TOKEN" ] && command -v gh &>/dev/null; then
              GH_TOKEN=$(gh auth token 2>/dev/null) || true
            fi
            if [ -n "$GH_TOKEN" ]; then
              printf '%s' "$GH_TOKEN" > "$CONFIG_DIR/gh-token"
              chmod 600 "$CONFIG_DIR/gh-token"
            fi

            # Remote builder setup (only if builder user exists on host)
            if id builder &>/dev/null; then
              ${vm.hostPkgs.openssh}/bin/ssh-keygen -t ed25519 -f "$CONFIG_DIR/builder-ssh-key" -N "" -C "claude-vm-ephemeral" -q

              BUILDER_AUTH_KEYS="/var/lib/builder/.ssh/authorized_keys"
              PUBKEY=$(cat "$CONFIG_DIR/builder-ssh-key.pub")
              RESTRICTED_ENTRY="restrict,no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $PUBKEY"

              sudo mkdir -p /var/lib/builder/.ssh
              sudo chmod 700 /var/lib/builder/.ssh
              sudo chown builder:users /var/lib/builder/.ssh
              echo "$RESTRICTED_ENTRY" | sudo tee -a "$BUILDER_AUTH_KEYS" > /dev/null
              sudo chmod 600 "$BUILDER_AUTH_KEYS"
              sudo chown builder:users "$BUILDER_AUTH_KEYS"

              if [ -f /etc/ssh/ssh_host_ed25519_key.pub ]; then
                cp /etc/ssh/ssh_host_ed25519_key.pub "$CONFIG_DIR/host-ssh-pubkey"
              fi

              cleanup() {
                sudo ${vm.hostPkgs.gnused}/bin/sed -i '/claude-vm-ephemeral$/d' "$BUILDER_AUTH_KEYS" 2>/dev/null || true
                rm -rf "$CONFIG_DIR"
              }
            else
              cleanup() {
                rm -rf "$CONFIG_DIR"
              }
            fi
            trap cleanup EXIT

            export CLAUDE_VM_CONFIG_DIR="$CONFIG_DIR"
            export WORKSPACE_DIR="$(pwd)"
            export CLAUDE_HOST_CONFIG_DIR="''${CLAUDE_HOST_CONFIG_DIR:-$HOME/.claude}"
            mkdir -p "$CLAUDE_HOST_CONFIG_DIR"
            ${setupVirtio}/bin/setup-virtio ${vmBuild}/bin/run-claude-vm-vm
          '';
        }
      );

      apps = forAllSystems (hostSystem: {
        default = {
          type = "app";
          program = "${self.packages.${hostSystem}.default}/bin/claude-vm";
        };
      });
    };
}
