{ pkgs, ... }:
let
  # Renovate's nix manager invokes the bare `nix` binary from PATH. Route it
  # through a chroot store ("local?root=") under the writable work volume so
  # `nix flake update` never writes into the image's read-only /nix/store:
  # fetched trees and the nix db live under /tmp/renovate/nix-root and vanish
  # with the CronJob's emptyDir — same freshness profile as the CI runner
  # this replaces.
  nixRootless = pkgs.writeShellScriptBin "nix" ''
    root="''${NIX_STORE_ROOT:-/tmp/renovate/nix-root}"
    mkdir -p "$root/nix/store" "$root/nix/var/nix/db" "$root/nix/var/nix/temproots"
    exec ${pkgs.nix}/bin/nix --store "$root" "$@"
  '';
in
{
  sourceUrl = "https://github.com/renovatebot/renovate";
  # 44.151.2 at lock rev 3ec6363 — ships the nix manager's flake.lock
  # lockFileMaintenance, which shells out to `nix flake update`.
  pkg = pkgs.renovate;
  # Batch/CronJob image: nothing listens on a port, but the app contract
  # requires one; it only shows up as harmless ExposedPorts metadata.
  port = 80;
  volumes = [ ];
  # Renovate shells out to the system `git` binary and the nix manager needs
  # `nix`; nodejs must be on PATH for child processes. The rootless-nix shim
  # is first so it shadows the store-backed nix for every invocation.
  extraContents = [ nixRootless pkgs.git pkgs.nix pkgs.nodejs ];
  extraPath = [ nixRootless pkgs.git pkgs.nix pkgs.nodejs ];
  # Writable HOME (git config/caches, chroot store); the CronJob mounts an
  # emptyDir at /tmp/renovate (RENOVATE_BASE_DIR).
  extraEnv = [ "HOME=/tmp/renovate" ];
  # Pre-create the writable /tmp tree so bare `docker run` smoke tests work
  # too (the CronJob's emptyDir mounts over it anyway). The container keeps
  # a writable rootfs (no readOnlyRootFilesystem on the renovate CronJob).
  #
  # NOTE: fakeRootCommands run inside the customisation layer — a symlinkJoin
  # of `contents` under `bash -e`. There is NO ./nix in that tree (store
  # contents live in separate store layers), so never chown/mkdir the store
  # from here; a failing command aborts the whole image build.
  extraFakeRootCommands = ''
    mkdir -p ./tmp/renovate
    chown -R 1000:1000 ./tmp
  '';
}
