{
  description = "OCI images for the home cluster, built from nixpkgs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    lib = pkgs.lib;

    # The flake input's locked nixpkgs revision; the image builders stamp
    # it into the dev.zunin.nixpkgs-revision label.
    nixpkgsRev = nixpkgs.rev;

    mkImage = pkgs.callPackage ./lib/mk-image.nix { inherit nixpkgsRev; };
    phpLib = pkgs.callPackage ./lib/mk-php-image.nix { inherit nixpkgsRev; };

    # One file per app in apps/ (e.g. apps/navidrome.nix): ports/volumes/env
    # must match the fleet manifests. Files with a leading "_" are skipped
    # (blocked apps, e.g. apps/_spoolman.nix).
    appFiles = lib.filter (name:
      lib.hasSuffix ".nix" name && !lib.hasPrefix "_" name
    ) (builtins.attrNames (builtins.readDir ./apps));

    apps = builtins.listToAttrs (map (file:
      let name = lib.removeSuffix ".nix" file;
      in {
        inherit name;
        value = pkgs.callPackage (./apps + "/${file}") {
          inherit (phpLib) mkPhpImage mkPhpExts phpWithExts;
        };
      }
    ) appFiles);

    # Each app's image builder result: { image, fingerprint }. PHP apps set
    # `image = mkPhpImage {...}` in their own file; the rest go through mkImage.
    images = builtins.mapAttrs (name: app:
      app.image or (mkImage {
        pname = name;
        pkg = app.pkg;
        port = app.port;
        volumes = app.volumes;
        cmdArgs = app.cmdArgs or [ ];
        extraEnv = app.extraEnv or [ ];
        cmd = app.cmd or null;
        extraContents = app.extraContents or [ ];
        workdir = app.workdir or null;
        extraPath = app.extraPath or [ ];
        extraFakeRootCommands = app.extraFakeRootCommands or "";
        sourceUrl = app.sourceUrl or "https://github.com/zunin/nix-images";
      })
    ) apps;
  in {
    packages.${system} =
      (builtins.mapAttrs (name: a: a.pkg) apps)
      // (lib.mapAttrs' (name: v: { name = "${name}-image"; value = v.image; }) images);

    # Build-inputs fingerprints (plain strings, computable without building)
    # so CI can skip rebuilding images whose inputs are unchanged.
    imageFingerprints.${system} = builtins.mapAttrs (name: v: v.fingerprint) images;
  };
}
