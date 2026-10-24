{ pkgs, mkPhpImage, ... }:
{
  pkg = pkgs.freshrss; # 1.30.1
  image = mkPhpImage {
    pname = "freshrss";
    sourceUrl = "https://github.com/FreshRSS/FreshRSS";
    pkg = pkgs.freshrss;
    webroot = "${pkgs.freshrss}/p";
    port = 8080;
    volumes = [ "/data" "/extensions" ];
    dirs = [ "/data" "/extensions" ];
    extraEnv = [ "DATA_PATH=/data" ];
  };
}
