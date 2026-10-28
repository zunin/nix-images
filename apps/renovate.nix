{ pkgs, ... }: {
  sourceUrl = "https://github.com/renovatebot/renovate";
  # 44.151.2 at lock rev 3ec6363 — ships the nix manager's flake.lock
  # lockFileMaintenance, which shells out to `nix flake update`.
  pkg = pkgs.renovate;
  # Batch/CronJob image: nothing listens on a port, but the app contract
  # requires one; it only shows up as harmless ExposedPorts metadata.
  port = 80;
  volumes = [ ];
  # Renovate shells out to the system `git` binary, the nix manager needs
  # the `nix` CLI, and nodejs must be on PATH for child processes.
  extraContents = [ pkgs.git pkgs.nix pkgs.nodejs ];
  extraPath = [ pkgs.git pkgs.nix pkgs.nodejs ];
  # Writable HOME for git config / caches; the CronJob mounts an emptyDir
  # at /tmp/renovate (RENOVATE_BASE_DIR).
  extraEnv = [ "HOME=/tmp/renovate" ];
  # `nix flake update` fetches tarballs INTO /nix/store and inits its
  # sqlite db under /nix/var/nix — as the image user (UID 1000), so the
  # store *directory* must be user-owned and writable. Existing store
  # paths stay root-owned: nix never mutates them, only adds new ones.
  # The container must therefore keep a writable rootfs (no
  # readOnlyRootFilesystem on the renovate CronJob).
  extraFakeRootCommands = ''
    chown 1000:1000 ./nix ./nix/store
    chmod u+w ./nix/store
    mkdir -p ./nix/var/nix/db ./nix/var/nix/temproots ./nix/var/nix/builds
    chown -R 1000:1000 ./nix/var
  '';
}
