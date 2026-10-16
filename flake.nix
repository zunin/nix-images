{
  description = "OCI images for the home cluster, built from nixpkgs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    # Shared image builder. Every image gets the same story:
    # non-root (UID 1000), a read-only /nix/store, and writable dirs
    # that the kro Application mounts PVCs over at runtime.
    mkImage = { pname, pkg, port ? 80, volumes ? [ ], cmdArgs ? [ ], extraEnv ? [ ], cmd ? null, extraContents ? [ ] }:
    pkgs.dockerTools.buildLayeredImage {
      # Placeholder owner (lowercase — docker rejects uppercase repos);
      # CI retags to ghcr.io/<repo-owner>/<pname> before pushing.
      name = "ghcr.io/owner/${pname}";
      # The mutable app-version tag. CI additionally publishes an immutable
      # <version>-<run_number> tag (base/OS patches keep <version>, new digests).
      tag = pkg.version;

      # The package's full runtime closure (ffmpeg, node, native libs) is
      # included automatically. No base image to maintain.
      contents = [ pkg ] ++ extraContents;

      # Make the writable dirs exist and belong to the image user.
      # In-cluster the PVCs overlay these; ownership only matters for `docker run`.
      # Runs under fakeroot with cwd = the image root, hence RELATIVE paths
      # (absolute paths would hit the read-only build sandbox root).
      fakeRootCommands = pkgs.lib.optionalString (volumes != [ ]) ''
        mkdir -p ${builtins.concatStringsSep " " (map (v: ".${v}") volumes)}
        chown -R 1000:1000 ${builtins.concatStringsSep " " (map (v: ".${v}") volumes)}
      '';

      # Fixed timestamp -> reproducible digests.
      created = "1970-01-01T00:00:00.000Z";

      config = {
        User = "1000:1000";
        ExposedPorts = { "${toString port}/tcp" = { }; };
        Volumes = builtins.listToAttrs (map (v: { name = v; value = { }; }) volumes);
        WorkingDir = if volumes == [ ] then "/" else builtins.head volumes;
        Cmd = (if cmd != null then cmd else [ (pkgs.lib.getExe pkg) ]) ++ cmdArgs;
        Env = extraEnv;
        Labels = {
          "org.opencontainers.image.title" = pname;
          "org.opencontainers.image.source" = "https://github.com/zunin/nix-images";
          "org.opencontainers.image.version" = pkg.version;
        };
      };
    };

    # One entry per app. `pkg` comes from nixpkgs; ports/volumes must match the
    # kro Application CR (audiobook-application.yaml / music-application.yaml).
    apps = {
      audiobookshelf = {
        pkg = pkgs.audiobookshelf; # nixpkgs: 2.37.1
        port = 80;                 # audiobook-application.yaml (container.port)
        volumes = [ "/config" "/audiobooks" "/metadata" "/podcasts" ];
        # The nixpkgs wrapper ignores PORT/CONFIG_PATH/METADATA_PATH env and only
        # reads CLI flags (defaults: 8000, $(pwd)/config, $(pwd)/metadata), so we
        # pass them explicitly to match the Application CR / official image.
        cmdArgs = [ "--port" "80" "--host" "0.0.0.0" "--config" "/config" "--metadata" "/metadata" ];
        # Serve at the root (nixpkgs default is a /audiobookshelf subpath).
        extraEnv = [ "ROUTER_BASE_PATH=/" ];
      };
      navidrome = {
        pkg = pkgs.navidrome;      # nixpkgs: 0.64.2
        port = 4533;               # music-application.yaml (container.port / ND_PORT)
        volumes = [ "/data" "/music" ];
      };
      # spoolman — BLOCKED at this nixpkgs rev: `python3.12-anyio-4.14.2` is not
      # in cache.nixos.org, so it builds from source and its test suite fails in
      # the sandbox ("5 failed, 2595 passed"), which blocks spoolman either here
      # or on CI. Re-enable on a rev bump, or carry a doCheck=false override.
      # spoolman = {
      #   pkg = pkgs.spoolman;     # nixpkgs: 0.23.1
      #   port = 7912;             # spoolman.deployment.yaml (SPOOLMAN_PORT)
      #   volumes = [ ];           # uses external postgres, no local data dir
      # };
      writefreely = {
        pkg = pkgs.writefreely;    # nixpkgs: 0.17.2
        port = 8080;               # writefreely default server port
        volumes = [ "/data" ];     # config.ini + data dir
      };
      freshrss = {
        pkg = pkgs.freshrss;       # nixpkgs: 1.30.1 (PHP web app, no mainProgram)
        port = 80;
        volumes = [ "/data" "/extensions" ];
        # PHP app: no binary, so serve it with PHP's built-in server.
        # (Analysis/pilot image; a production setup wants php-fpm + a webserver.)
        extraContents = [ pkgs.php ];
        cmd = [ "${pkgs.php}/bin/php" "-S" "0.0.0.0:80" "-t" "${pkgs.freshrss}" ];
      };
    };
  in {
    # `.#audiobookshelf` = the nixpkgs package (so CI can read `.version`),
    # `.#audiobookshelf-image` = the runnable OCI archive for `docker load`.
    packages.${system} =
      (builtins.mapAttrs (name: a: a.pkg) apps)
      // (builtins.listToAttrs (builtins.map (name: {
            name = "${name}-image";
            value = mkImage {
              pname = name;
              pkg = apps.${name}.pkg;
              port = apps.${name}.port;
              volumes = apps.${name}.volumes;
              cmdArgs = apps.${name}.cmdArgs or [ ];
              extraEnv = apps.${name}.extraEnv or [ ];
              cmd = apps.${name}.cmd or null;
              extraContents = apps.${name}.extraContents or [ ];
            };
          }) (builtins.attrNames apps)));
  };
}