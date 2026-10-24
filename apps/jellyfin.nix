{ pkgs, ... }:
{
  sourceUrl = "https://github.com/jellyfin/jellyfin";
  pkg = pkgs.jellyfin; # 12.2
  port = 8096;
  volumes = [ "/config" "/media" "/cache" ];
  cmdArgs = [ "--datadir" "/config" "--configdir" "/config/config" "--cachedir" "/cache" "--logdir" "/config/log" ];
}
