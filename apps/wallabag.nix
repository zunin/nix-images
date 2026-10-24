{ pkgs, mkPhpImage, ... }:
{
  pkg = pkgs.wallabag; # 2.6.14
  image = mkPhpImage {
    pname = "wallabag";
    sourceUrl = "https://github.com/wallabag/wallabag";
    pkg = pkgs.wallabag;
    webroot = "${pkgs.wallabag}/web";
    port = 8080;
    # web/ has no index.php — the prod front controller is app.php.
    entryFile = "app.php";
    # DownloadImages saves to %kernel.project_dir%/web/assets/images
    # (= /config/web/assets/images via WALLABAG_DATA) and emits
    # /assets/images/... URLs; serve those from the PVC, not the store.
    extraCaddy = ''
      handle_path /assets/images/* {
        root * /config/web/assets/images
        file_server
      }
    '';
    volumes = [ "/config" ];
    dirs = [ "/config" ];
    seed = [ { from = "${pkgs.wallabag}/app"; to = "/config/app"; } ];
    symlinks = [
      # services.yml resolves bundle resources as ../../src/... relative
      # to the seeded config dir (/config/app/config) — /config/src must
      # exist.
      { from = "${pkgs.wallabag}/src"; to = "/config/src"; }
      # App-level template overrides (templates/bundles/FOSUserBundle/…)
      # and translations resolve under %kernel.project_dir% (=/config);
      # without them Symfony falls back to FOSUserBundle's bare layout
      # (unstyled login page).
      { from = "${pkgs.wallabag}/templates"; to = "/config/templates"; }
      { from = "${pkgs.wallabag}/translations"; to = "/config/translations"; }
    ];
    # parameters.yml comes from the fleet (Secret mounted at /params);
    # the dist copy is pdo_mysql and cannot boot.
    params = { from = "/params"; to = "/config/app/config"; };
    extraEnv = [ "WALLABAG_DATA=/config" ];
    # Symfony container/twig cache lives under project dir.
    cacheDir = "/config/var/cache";
  };
}
