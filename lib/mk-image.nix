# Shared image builder. Every image gets the same story:
# non-root (UID 1000), a read-only /nix/store, and writable dirs
# that the kro Application mounts PVCs over at runtime.
#
# Takes { pkgs, nixpkgsRev } (the flake input's locked revision, used for
# the dev.zunin.nixpkgs-revision label) and returns the builder function,
# which returns { image, fingerprint }.
{ pkgs, nixpkgsRev }:
{ pname, pkg, port ? 80, volumes ? [ ], cmdArgs ? [ ], extraEnv ? [ ], cmd ? null, extraContents ? [ ], workdir ? null, extraPath ? [ ], extraFakeRootCommands ? "", sourceUrl ? "https://github.com/zunin/nix-images" }:
let
  lib = pkgs.lib;

  # Exact fingerprint of everything that shapes this image. It is computable
  # at eval time (no build), so CI compares it with the published image's
  # label and skips the build+push entirely when it matches — covering
  # byte-identical rebuilds and nondeterministic ones alike (same inputs,
  # same fingerprint, even if the bytes differ).
  fingerprint = builtins.hashString "sha256" (builtins.toJSON {
    builder = builtins.hashFile "sha256" ./mk-image.nix;
    inherit pname port volumes cmdArgs extraEnv cmd workdir sourceUrl;
    inherit (pkg) outPath;
    nixpkgs = nixpkgsRev;
    extraContents = map (p: "${p}") extraContents;
    extraPath = map (p: "${p}") extraPath;
    inherit extraFakeRootCommands;
  });
in
{
  inherit fingerprint;

  image = pkgs.dockerTools.buildLayeredImage {
    # Placeholder owner (lowercase — docker rejects uppercase repos);
    # CI retags to ghcr.io/<repo-owner>/<pname> before pushing.
    name = "ghcr.io/owner/${pname}";
    # The mutable app-version tag. CI additionally publishes an immutable
    # <version>-<run_number> tag (base/OS patches keep <version>, new digests).
    tag = pkg.version;

    # The package's full runtime closure, plus coreutils/bash so apps that
    # shell out to `uname`/`env`/`sh` don't crash (distro-less image).
    contents = [ pkg ] ++ extraContents ++ [ pkgs.coreutils pkgs.bashInteractive pkgs.cacert ];

    # Make the writable dirs exist and belong to the image user.
    # Runs under fakeroot with cwd = the image root, hence RELATIVE paths.
    # /etc/passwd entry so uid 1000 resolves — .NET apps (kavita) call
    # get_UserName() and crash without it. Plus the writable volume dirs.
    fakeRootCommands = ''
      mkdir -p ./etc
      printf 'nixapp:x:1000:1000:nix app:/:/sbin/nologin\n' > ./etc/passwd
      printf 'nixapp:x:1000:\n' > ./etc/group
      # minimal FHS bits — some apps spawn uname/env/sh
      mkdir -p ./bin ./usr/bin
      ln -sf ${pkgs.bashInteractive}/bin/bash ./bin/sh
      ln -sf ${pkgs.bashInteractive}/bin/bash ./bin/bash
      ln -sf ${pkgs.coreutils}/bin/env ./usr/bin/env
      # CA bundle for outbound HTTPS (Go: SSL_CERT_FILE, OpenSSL: /etc/ssl/certs)
      mkdir -p ./etc/ssl/certs
      ln -sf ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ./etc/ssl/certs/ca-bundle.crt
      ${lib.optionalString (volumes != [ ]) ''
        mkdir -p ${builtins.concatStringsSep " " (map (v: ".${v}") volumes)}
        chown -R 1000:1000 ${builtins.concatStringsSep " " (map (v: ".${v}") volumes)}
      ''}
      # App-provided fakeroot setup, e.g. pre-creating writable runtime dirs
      # (apps/renovate.nix pre-creates /tmp/renovate). NOTE: this runs in the
      # customisation layer — a symlinkJoin of `contents` — which has no
      # ./nix (store contents live in separate store layers), and under
      # `bash -e`: a failing command here fails the whole image build.
      ${extraFakeRootCommands}
    '';

    # Fixed timestamp -> reproducible digests.
    created = "1970-01-01T00:00:00.000Z";

    config = {
      User = "1000:1000";
      ExposedPorts = { "${toString port}/tcp" = { }; };
      Volumes = builtins.listToAttrs (map (v: { name = v; value = { }; }) volumes);
      WorkingDir = if workdir != null then workdir else (if volumes == [ ] then "/" else builtins.head volumes);
      Cmd = (if cmd != null then cmd else [ (lib.getExe pkg) ]) ++ cmdArgs;
      Env = [ "PATH=${lib.makeBinPath ([ pkgs.coreutils pkgs.bashInteractive ] ++ extraPath)}" "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ] ++ extraEnv;
      Labels = {
        "org.opencontainers.image.title" = pname;
        "org.opencontainers.image.source" = sourceUrl;
        "org.opencontainers.image.version" = pkg.version;
        # nixpkgs revision the image was built from (custom namespace: the
        # standard revision label would make Renovate treat upstream release
        # notes as nixpkgs commits).
        "dev.zunin.nixpkgs-revision" = nixpkgsRev;
        # Build-inputs fingerprint; CI skips build/push when the published
        # image already carries the same value.
        "dev.zunin.build-fingerprint" = fingerprint;
      };
    };
  };
}
