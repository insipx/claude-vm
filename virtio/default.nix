{ pkgs, ... }:
pkgs.writeShellScriptBin "setup-virtio" (
  builtins.replaceStrings [ "@virtiofsd@" ] [ "${pkgs.virtiofsd}/bin/virtiofsd" ] (
    builtins.readFile ./setup-virtio.sh
  )
)
