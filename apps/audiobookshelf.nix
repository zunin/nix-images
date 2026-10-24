# nixpkgs builds the audiobookshelf web client with router base
# /audiobookshelf (the ROUTER_BASE_PATH default). Rebuild just the client
# with an empty base so it serves at the root (matching the Application CR
# and the official image), then swap its dist into the package.
{ pkgs, ... }:
let
  audiobookshelfRoot = pkgs.audiobookshelf.overrideAttrs (old: rec {
    clientRoot = pkgs.buildNpmPackage {
      pname = "audiobookshelf-client";
      version = old.version;
      src = "${old.src}/client";
      npmDepsHash = "sha256-Rvy/bULWyVkGthfpIGkTMO8Lv1miywwea7jLODfm54Y=";
      env = {
        CYPRESS_INSTALL_BINARY = "0";
        NODE_OPTIONS = "--openssl-legacy-provider";
        ROUTER_BASE_PATH = "";
      };
      npmBuildScript = "generate";
      nodejs = pkgs.nodejs_24;
    };
    postFixup = (old.postFixup or "") + ''
      rm -rf "$out/opt/client/dist"
      cp -r ${clientRoot}/lib/node_modules/audiobookshelf-client/dist "$out/opt/client/dist"
    '';
  });
in
{
  sourceUrl = "https://github.com/advplyr/audiobookshelf";
  pkg = audiobookshelfRoot; # 2.37.1, client rebuilt with base ""
  port = 80;
  volumes = [ "/config" "/audiobooks" "/metadata" "/podcasts" ];
  # wrapper ignores PORT/CONFIG_PATH/METADATA_PATH env; only CLI flags.
  cmdArgs = [ "--port" "80" "--host" "0.0.0.0" "--config" "/config" "--metadata" "/metadata" ];
  extraEnv = [ "ROUTER_BASE_PATH=/" ];
}
