{ pkgs, ... }:
{
  sourceUrl = "https://github.com/jellyfin/jellyfin";
  pkg = pkgs.jellyfin; # 12.2
  port = 8096;
  volumes = [ "/config" "/media" "/cache" ];
  cmdArgs = [ "--datadir" "/config" "--configdir" "/config/config" "--cachedir" "/cache" "--logdir" "/config/log" ];
  # FFmpeg/libass need fontconfig for subtitles. The package supplies a config
  # and DejaVu fonts, but unlike the official image there is no /etc/fonts.
  extraEnv = [
    "FONTCONFIG_FILE=${pkgs.fontconfig}/etc/fonts/fonts.conf"
    "XDG_CACHE_HOME=/cache"
  ];
}
