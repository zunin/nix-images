# nixpkgs now exposes a routerBasePath argument, plumbed into both the
# client build (env.ROUTER_BASE_PATH) and the server wrapper (--set).
# Fleet serves audiobookshelf at the root, so empty base. This replaces
# the previous client-rebuild override, which was needed when nixpkgs
# baked the client with base /audiobookshelf and gave no way to change
# it (pre-3ec6363 packaging; old layout broke with the 2026-10-25
# flake.lock bump).
{ pkgs, ... }:
{
  sourceUrl = "https://github.com/advplyr/audiobookshelf";
  pkg = pkgs.audiobookshelf.override { routerBasePath = ""; }; # 2.37.1
  port = 80;
  volumes = [ "/config" "/audiobooks" "/metadata" "/podcasts" ];
  # wrapper ignores PORT/CONFIG_PATH/METADATA_PATH env; only CLI flags.
  cmdArgs = [ "--port" "80" "--host" "0.0.0.0" "--config" "/config" "--metadata" "/metadata" ];
}