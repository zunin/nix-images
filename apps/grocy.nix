{ pkgs, mkPhpImage, mkPhpExts, ... }:
{
  pkg = pkgs.grocy; # 4.7.1
  image = mkPhpImage {
    pname = "grocy";
    sourceUrl = "https://github.com/grocy/grocy";
    pkg = pkgs.grocy;
    webroot = "${pkgs.grocy}/public";
    port = 8080;
    # grocy 4.7.1 hard-requires PHP >= 8.5 (boot-tested: 8.4 → HTTP 500).
    php = mkPhpExts pkgs.php85;
    volumes = [ "/config" ];
    dirs = [ "/config" "/config/storage" "/config/plugins" "/config/viewcache" ];
    seed = [ { from = "${pkgs.grocy}/config-dist.php"; to = "/config/config.php"; } ];
    extraEnv = [
      "GROCY_CONFIG_FILE=/config/config.php"
      "GROCY_DB_FILE=/config/grocy.db"
      "GROCY_STORAGE_DIR=/config/storage"
      "GROCY_PLUGIN_DIR=/config/plugins"
      "GROCY_CACHE_DIR=/config/viewcache"
    ];
  };
}
