{ pkgs, ... }:
{
  sourceUrl = "https://github.com/asciimoo/hister";
  pkg = pkgs.hister; # 0.20.0
  port = 4433;
  volumes = [ "/hister/search-data" "/hister/data" ];
  # `hister` with no args is the client CLI; `listen` starts the server.
  cmdArgs = [ "listen" ];
  # config.yml lives in /hister/data and is read from cwd (./config.yml).
  workdir = "/hister/data";
  extraPath = [ pkgs.hister ]; # fleet crawler cronjob calls bare `hister`
  extraEnv = [ "HISTER__SERVER__ADDRESS=0.0.0.0:4433" "HISTER_DATA_DIR=/hister/search-data" ];
}
