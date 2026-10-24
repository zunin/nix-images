{ pkgs, ... }:
{
  sourceUrl = "https://github.com/writefreely/writefreely";
  pkg = pkgs.writefreely; # 0.17.2
  port = 8080;
  volumes = [ "/data" ];
}
