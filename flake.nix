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
    mkImage = { pname, pkg, port ? 80, volumes ? [ ] }:
    pkgs.dockerTools.buildLayeredImage {
      # Placeholder owner (lowercase — docker rejects uppercase repos);
      # CI retags to ghcr.io/<repo-owner>/<pname> before pushing.
      name = "ghcr.io/owner/${pname}";
      # The mutable app-version tag. CI additionally publishes an immutable
      # <version>-<run_number> tag (base/OS patches keep <version>, new digests).
      tag = pkg.version;

      # The package's full runtime closure (ffmpeg, node, native libs) is
      # included automatically. No base image to maintain.
      contents = [ pkg ];

      # Make the writable dirs exist and belong to the image user.
      # In-cluster the PVCs overlay these; ownership only matters for `docker run`.
      # Runs under fakeroot with cwd = the image root, hence RELATIVE paths
      # (absolute paths would hit the read-only build sandbox root).
      fakeRootCommands = ''
        mkdir -p ${builtins.concatStringsSep " " (map (v: ".${v}") volumes)}
        chown -R 1000:1000 ${builtins.concatStringsSep " " (map (v: ".${v}") volumes)}
      '';

      # Fixed timestamp -> reproducible digests.
      created = "1970-01-01T00:00:00.000Z";

      config = {
        User = "1000:1000";
        ExposedPorts = { "${toString port}/tcp" = { }; };
        Volumes = builtins.listToAttrs (map (v: { name = v; value = { }; }) volumes);
        WorkingDir = builtins.head volumes;
        Cmd = [ (pkgs.lib.getExe pkg) ];
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
      };
      navidrome = {
        pkg = pkgs.navidrome;      # nixpkgs: 0.64.2
        port = 4533;               # music-application.yaml (container.port / ND_PORT)
        volumes = [ "/data" "/music" ];
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
            };
          }) (builtins.attrNames apps)));
  };
}