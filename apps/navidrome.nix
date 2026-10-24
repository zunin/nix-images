{ pkgs, ... }:
{
  sourceUrl = "https://github.com/navidrome/navidrome";
  pkg = pkgs.navidrome; # 0.64.2
  port = 4533;
  volumes = [ "/data" "/music" ];
}
