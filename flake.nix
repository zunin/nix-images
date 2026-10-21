{
  description = "OCI images for the home cluster, built from nixpkgs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    lib = pkgs.lib;

    # Shared image builder. Every image gets the same story:
    # non-root (UID 1000), a read-only /nix/store, and writable dirs
    # that the kro Application mounts PVCs over at runtime.
    mkImage = { pname, pkg, port ? 80, volumes ? [ ], cmdArgs ? [ ], extraEnv ? [ ], cmd ? null, extraContents ? [ ], workdir ? null, extraPath ? [ ], sourceUrl ? "https://github.com/zunin/nix-images" }:
    pkgs.dockerTools.buildLayeredImage {
      # Placeholder owner (lowercase — docker rejects uppercase repos);
      # CI retags to ghcr.io/<repo-owner>/<pname> before pushing.
      name = "ghcr.io/owner/${pname}";
      # The mutable app-version tag. CI additionally publishes an immutable
      # <version>-<run_number> tag (base/OS patches keep <version>, new digests).
      tag = pkg.version;

      # The package's full runtime closure, plus coreutils/bash so apps that
      # shell out to `uname`/`env`/`sh` don't crash (distro-less image).
      contents = [ pkg ] ++ extraContents ++ [ pkgs.coreutils pkgs.bashInteractive pkgs.cacert ];

      # Make the writable dirs exist and belong to the image user.
      # Runs under fakeroot with cwd = the image root, hence RELATIVE paths.
      # /etc/passwd entry so uid 1000 resolves — .NET apps (kavita) call
      # get_UserName() and crash without it. Plus the writable volume dirs.
      fakeRootCommands = ''
        mkdir -p ./etc
        printf 'nixapp:x:1000:1000:nix app:/:/sbin/nologin\n' > ./etc/passwd
        printf 'nixapp:x:1000:\n' > ./etc/group
        # minimal FHS bits — some apps spawn uname/env/sh
        mkdir -p ./bin ./usr/bin
        ln -sf ${pkgs.bashInteractive}/bin/bash ./bin/sh
        ln -sf ${pkgs.bashInteractive}/bin/bash ./bin/bash
        ln -sf ${pkgs.coreutils}/bin/env ./usr/bin/env
        # CA bundle for outbound HTTPS (Go: SSL_CERT_FILE, OpenSSL: /etc/ssl/certs)
        mkdir -p ./etc/ssl/certs
        ln -sf ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ./etc/ssl/certs/ca-bundle.crt
        ${lib.optionalString (volumes != [ ]) ''
          mkdir -p ${builtins.concatStringsSep " " (map (v: ".${v}") volumes)}
          chown -R 1000:1000 ${builtins.concatStringsSep " " (map (v: ".${v}") volumes)}
        ''}
      '';

      # Fixed timestamp -> reproducible digests.
      created = "1970-01-01T00:00:00.000Z";

      config = {
        User = "1000:1000";
        ExposedPorts = { "${toString port}/tcp" = { }; };
        Volumes = builtins.listToAttrs (map (v: { name = v; value = { }; }) volumes);
        WorkingDir = if workdir != null then workdir else (if volumes == [ ] then "/" else builtins.head volumes);
        Cmd = (if cmd != null then cmd else [ (lib.getExe pkg) ]) ++ cmdArgs;
        Env = [ "PATH=${lib.makeBinPath ([ pkgs.coreutils pkgs.bashInteractive ] ++ extraPath)}" "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ] ++ extraEnv;
        Labels = {
          "org.opencontainers.image.title" = pname;
          "org.opencontainers.image.source" = sourceUrl;
          "org.opencontainers.image.version" = pkg.version;
        };
      };
    };

    # nixpkgs builds the audiobookshelf web client with router base
    # /audiobookshelf (the ROUTER_BASE_PATH default). Rebuild just the client
    # with an empty base so it serves at the root (matching the Application CR
    # and the official image), then swap its dist into the package.
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

    # --- PHP support ---------------------------------------------------------
    # PHP web apps (grocy, wallabag, freshrss) have no runnable binary. Serve
    # them with php-fpm + Caddy (FastCGI) as a non-root user on an unprivileged
    # port (the fleet Service maps :80 -> the container port).
    mkPhpExts = php: php.withExtensions ({ enabled, all }:
      # filter by what the target PHP actually exposes: newer PHPs drop
      # separate attrs for bundled extensions (php85 has no `opcache`).
      enabled ++ (map (n: all.${n})
        (lib.filter (n: all ? n)
          [ "pdo_sqlite" "sqlite3" "intl" "gd" "curl" "zip" "exif" "opcache" ])));
    # Default PHP (8.4). Apps needing a newer PHP pass `php = mkPhpExts pkgs.php85`.
    phpWithExts = mkPhpExts pkgs.php;

    mkPhpImage = { pname, pkg, webroot, port ? 8080, volumes ? [ ], dirs ? [ ], seed ? [ ], extraEnv ? [ ], php ? phpWithExts, entryFile ? "index.php", extraCaddy ? "", params ? null, symlinks ? [ ], cacheDir ? null, sourceUrl ? "https://github.com/zunin/nix-images" }:
    let
      fpmConf = pkgs.writeText "php-fpm.conf" ''
        [global]
        error_log = /proc/self/fd/2
        daemonize = no

        [www]
        listen = /tmp/php-fpm.sock
        listen.mode = 0666
        clear_env = no
        catch_workers_output = yes
        pm = dynamic
        pm.max_children = 10
        pm.start_servers = 2
        pm.min_spare_servers = 1
        pm.max_spare_servers = 3
        php_admin_value[error_log] = /proc/self/fd/2
        php_admin_flag[log_errors] = on
        ; Wallabag 2.6's vendor tree spews PHP 8.4 deprecations on every
        ; request; display would eat the output buffer and break redirects.
        ; (php-fpm ini files do not support '#' comments.)
        php_admin_value[display_errors] = off
        php_admin_value[error_reporting] = 22527 ; E_ALL & ~E_DEPRECATED & ~E_STRICT
      '';
      caddyfile = pkgs.writeText "Caddyfile" ''
        {
          admin off
          auto_https off
        }
        :${toString port} {
          root * ${webroot}
          encode gzip
          php_fastcgi unix//tmp/php-fpm.sock {
            index ${entryFile}
          }
          ${extraCaddy}
          file_server
        }
      '';
      entrypoint = pkgs.writeShellScriptBin "${pname}-entrypoint" ''
        set -eu
        mkdir -p /tmp ${lib.concatStringsSep " " dirs}
        ${lib.concatMapStringsSep "\n" (s: "if [ ! -e ${s.to} ]; then cp -a ${s.from} ${s.to}; chmod -R u+w ${s.to}; fi") seed}
        # Store paths change on every nixpkgs rev, so re-point on every boot.
        ${lib.concatMapStringsSep "\n" (s: "ln -sfn ${s.from} ${s.to}") symlinks}
        ${lib.optionalString (params != null) ''
        # Fleet-provided config files (e.g. a mounted Secret/ConfigMap dir)
        # overwrite the seeded dist copies after seeding.
        if [ -d ${params.from} ]; then cp -f ${params.from}/* ${params.to}/ || true; fi
        ''}
        export XDG_DATA_HOME=/tmp/caddy-data XDG_CONFIG_HOME=/tmp/caddy-config
        mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
        ${lib.optionalString (cacheDir != null) ''
        # Compiled containers (Symfony) bake in file-existence decisions and
        # service wiring; a stale cache across image upgrades caused the
        # FOSUserBundle bare layout long after templates/ were added. Drop the
        # cache whenever the app's store path changes.
        if [ -f ${cacheDir}/.image-marker ] && [ "$(cat ${cacheDir}/.image-marker)" != "${pkg}" ]; then
          rm -rf ${cacheDir}
        fi
        mkdir -p ${cacheDir}
        echo "${pkg}" > ${cacheDir}/.image-marker
        ''}
        ${php}/bin/php-fpm -F -y ${fpmConf} &
        exec ${pkgs.caddy}/bin/caddy run --config ${caddyfile} --adapter caddyfile
      '';
    in
    pkgs.dockerTools.buildLayeredImage {
      name = "ghcr.io/owner/${pname}";
      tag = pkg.version;
      contents = [ pkg entrypoint php pkgs.caddy pkgs.cacert ];
      fakeRootCommands = ''
        mkdir -p ./etc
        printf 'nixapp:x:1000:1000:nix app:/:/sbin/nologin\n' > ./etc/passwd
        printf 'nixapp:x:1000:\n' > ./etc/group
        mkdir -p ./bin ./usr/bin
        ln -sf ${pkgs.bashInteractive}/bin/bash ./bin/sh
        ln -sf ${pkgs.bashInteractive}/bin/bash ./bin/bash
        ln -sf ${pkgs.coreutils}/bin/env ./usr/bin/env
        # CA bundle for outbound HTTPS (Go: SSL_CERT_FILE, OpenSSL: /etc/ssl/certs)
        mkdir -p ./etc/ssl/certs
        ln -sf ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ./etc/ssl/certs/ca-bundle.crt
        mkdir -p ./tmp
        chown 1000:1000 ./tmp
        ${lib.optionalString (volumes != [ ]) ''
          mkdir -p ${builtins.concatStringsSep " " (map (v: ".${v}") volumes)}
          chown -R 1000:1000 ${builtins.concatStringsSep " " (map (v: ".${v}") volumes)}
        ''}
      '';
      created = "1970-01-01T00:00:00.000Z";
      config = {
        User = "1000:1000";
        ExposedPorts = { "${toString port}/tcp" = { }; };
        Volumes = builtins.listToAttrs (map (v: { name = v; value = { }; }) volumes);
        WorkingDir = "/";
        Cmd = [ "${entrypoint}/bin/${pname}-entrypoint" ];
        Env = [ "PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.bashInteractive php pkgs.caddy ]}" "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ] ++ extraEnv;
        Labels = {
          "org.opencontainers.image.title" = pname;
          "org.opencontainers.image.source" = sourceUrl;
          "org.opencontainers.image.version" = pkg.version;
        };
      };
    };

    # One entry per app: ports/volumes/env must match the fleet manifests.
    apps = {
      audiobookshelf = {
        sourceUrl = "https://github.com/advplyr/audiobookshelf";
        pkg = audiobookshelfRoot; # 2.37.1, client rebuilt with base ""
        port = 80;
        volumes = [ "/config" "/audiobooks" "/metadata" "/podcasts" ];
        # wrapper ignores PORT/CONFIG_PATH/METADATA_PATH env; only CLI flags.
        cmdArgs = [ "--port" "80" "--host" "0.0.0.0" "--config" "/config" "--metadata" "/metadata" ];
        extraEnv = [ "ROUTER_BASE_PATH=/" ];
      };
      navidrome = {
        sourceUrl = "https://github.com/navidrome/navidrome";
        pkg = pkgs.navidrome; # 0.64.2
        port = 4533;
        volumes = [ "/data" "/music" ];
      };
      kavita = {
        sourceUrl = "https://github.com/Kareadita/Kavita";
        pkg = pkgs.kavita; # 0.9.1.4
        port = 5000;
        volumes = [ "/kavita/config" "/media" ];
        # Kavita's config dir is <cwd>/config, so cwd must be the parent of the
        # /kavita/config mount (matches the existing PVC / official layout).
        workdir = "/kavita";
      };
      jellyfin = {
        sourceUrl = "https://github.com/jellyfin/jellyfin";
        pkg = pkgs.jellyfin; # 12.2
        port = 8096;
        volumes = [ "/config" "/media" "/cache" ];
        cmdArgs = [ "--datadir" "/config" "--configdir" "/config/config" "--cachedir" "/cache" "--logdir" "/config/log" ];
      };
      hister = {
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
      };
      writefreely = {
        sourceUrl = "https://github.com/writefreely/writefreely";
        pkg = pkgs.writefreely; # 0.17.2
        port = 8080;
        volumes = [ "/data" ];
      };
      freshrss = {
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
      };
      grocy = {
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
      };
      wallabag = {
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
      };
      # spoolman — BLOCKED: python3.12-anyio-4.14.2 uncached + failing tests at
      # this rev. Re-enable on a rev bump or with a doCheck=false override.
      # spoolman = { pkg = pkgs.spoolman; port = 7912; volumes = [ ]; };
    };
  in {
    packages.${system} =
      (builtins.mapAttrs (name: a: a.pkg) apps)
      // (builtins.listToAttrs (builtins.map (name: {
            name = "${name}-image";
            value = apps.${name}.image or (mkImage {
              pname = name;
              pkg = apps.${name}.pkg;
              port = apps.${name}.port;
              volumes = apps.${name}.volumes;
              cmdArgs = apps.${name}.cmdArgs or [ ];
              extraEnv = apps.${name}.extraEnv or [ ];
              cmd = apps.${name}.cmd or null;
              extraContents = apps.${name}.extraContents or [ ];
              workdir = apps.${name}.workdir or null;
              extraPath = apps.${name}.extraPath or [ ];
              sourceUrl = apps.${name}.sourceUrl or "https://github.com/zunin/nix-images";
            });
          }) (builtins.attrNames apps)));
  };
}