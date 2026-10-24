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
          inherit (phpLib) mkPhpImage mkPhpExts php84Patched php85Patched phpWithExts;
        };
      }
    ) appFiles);
  in {
    packages.${system} =
      (builtins.mapAttrs (name: a: a.pkg) apps)
      // (builtins.listToAttrs (builtins.map (name: {
            name = "${name}-image";
            value = apps.${name}.image or (mkImage {
              pname = name;
              pkg = apps.${name}.pkg;
              port = apps.${name}.port;
              volumes = apps.${name}.volumes;
              cmdArgs = apps.${name}.cmdArgs or [ ];
              extraEnv = apps.${name}.extraEnv or [ ];
              cmd = apps.${name}.cmd or null;
              extraContents = apps.${name}.extraContents or [ ];
              workdir = apps.${name}.workdir or null;
              extraPath = apps.${name}.extraPath or [ ];
              sourceUrl = apps.${name}.sourceUrl or "https://github.com/zunin/nix-images";
            });
          }) (builtins.attrNames apps)));
  };
}
