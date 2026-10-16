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
    mkImage = { pname, pkg, port ? 80, volumes ? [ ], cmdArgs ? [ ], extraEnv ? [ ], cmd ? null, extraContents ? [ ], workdir ? null }:
    pkgs.dockerTools.buildLayeredImage {
      # Placeholder owner (lowercase — docker rejects uppercase repos);
      # CI retags to ghcr.io/<repo-owner>/<pname> before pushing.
      name = "ghcr.io/owner/${pname}";
      # The mutable app-version tag. CI additionally publishes an immutable
      # <version>-<run_number> tag (base/OS patches keep <version>, new digests).
      tag = pkg.version;

      # The package's full runtime closure, plus coreutils/bash so apps that
      # shell out to `uname`/`env`/`sh` don't crash (distro-less image).
      contents = [ pkg ] ++ extraContents ++ [ pkgs.coreutils pkgs.bashInteractive ];

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
        Env = [ "PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.bashInteractive ]}" ] ++ extraEnv;
        Labels = {
          "org.opencontainers.image.title" = pname;
          "org.opencontainers.image.source" = "https://github.com/zunin/nix-images";
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
    # PHP web apps (grocy, wallabag, freshrss) have no runnable binary. We serve
    # them with PHP's built-in server. This is a PILOT/analysis setup; a
    # production cutover wants php-fpm + a real webserver.
    phpWithExts = pkgs.php.withExtensions ({ enabled, all }:
      enabled ++ (with all; [ pdo_sqlite sqlite3 intl gd curl zip exif opcache ]));

    # Small entrypoint: create writable dirs, seed a config once, run php -S.
    mkPhpServer = { name, docroot, port, dirs ? [ ], seed ? [ ] }:
      pkgs.writeShellScriptBin name ''
        set -eu
        ${lib.concatMapStringsSep "\n" (d: "${pkgs.coreutils}/bin/mkdir -p ${d}") dirs}
        ${lib.concatMapStringsSep "\n" (s: "if [ ! -e ${s.to} ]; then ${pkgs.coreutils}/bin/cp -a ${s.from} ${s.to}; fi") seed}
        exec ${phpWithExts}/bin/php -S 0.0.0.0:${toString port} -t ${docroot}
      '';

    # One entry per app: ports/volumes/env must match the fleet manifests.
    apps = {
      audiobookshelf = {
        pkg = audiobookshelfRoot; # 2.37.1, client rebuilt with base ""
        port = 80;
        volumes = [ "/config" "/audiobooks" "/metadata" "/podcasts" ];
        # wrapper ignores PORT/CONFIG_PATH/METADATA_PATH env; only CLI flags.
        cmdArgs = [ "--port" "80" "--host" "0.0.0.0" "--config" "/config" "--metadata" "/metadata" ];
        extraEnv = [ "ROUTER_BASE_PATH=/" ];
      };
      navidrome = {
        pkg = pkgs.navidrome; # 0.64.2
        port = 4533;
        volumes = [ "/data" "/music" ];
      };
      kavita = {
        pkg = pkgs.kavita; # 0.9.1.4
        port = 5000;
        volumes = [ "/kavita/config" "/media" ];
        # Kavita's config dir is <cwd>/config, so cwd must be the parent of the
        # /kavita/config mount (matches the existing PVC / official layout).
        workdir = "/kavita";
      };
      jellyfin = {
        pkg = pkgs.jellyfin; # 12.2
        port = 8096;
        volumes = [ "/config" "/media" "/cache" ];
        cmdArgs = [ "--datadir" "/config" "--configdir" "/config/config" "--cachedir" "/cache" "--logdir" "/config/log" ];
      };
      hister = {
        pkg = pkgs.hister; # 0.20.0
        port = 4433;
        volumes = [ "/hister/search-data" "/hister/data" ];
        # `hister` with no args is the client CLI; `listen` starts the server.
        cmdArgs = [ "listen" ];
        # config.yml lives in /hister/data and is read from cwd (./config.yml).
        workdir = "/hister/data";
        extraEnv = [ "HISTER__SERVER__ADDRESS=0.0.0.0:4433" "HISTER_DATA_DIR=/hister/search-data" ];
      };
      writefreely = {
        pkg = pkgs.writefreely; # 0.17.2
        port = 8080;
        volumes = [ "/data" ];
      };
      freshrss = {
        pkg = pkgs.freshrss; # 1.30.1 (webroot: p/) — DATA_PATH env; web installer seeds config.
        port = 80;
        volumes = [ "/data" "/extensions" ];
        extraContents = [ phpWithExts ];
        extraEnv = [ "DATA_PATH=/data" ];
        cmd = [ "${mkPhpServer { name = "freshrss-server"; docroot = "${pkgs.freshrss}/p"; port = 80; dirs = [ "/data" "/extensions" ]; }}/bin/freshrss-server" ];
      };
      grocy = {
        pkg = pkgs.grocy; # 4.7.1 (webroot: public/)
        port = 80;
        volumes = [ "/config" ];
        extraContents = [ phpWithExts ];
        extraEnv = [
          "GROCY_CONFIG_FILE=/config/config.php"
          "GROCY_DB_FILE=/config/grocy.db"
          "GROCY_STORAGE_DIR=/config/storage"
          "GROCY_PLUGIN_DIR=/config/plugins"
          "GROCY_CACHE_DIR=/config/viewcache"
        ];
        cmd = [ "${mkPhpServer {
          name = "grocy-server";
          docroot = "${pkgs.grocy}/public";
          port = 80;
          dirs = [ "/config" "/config/storage" "/config/plugins" "/config/viewcache" ];
          seed = [ { from = "${pkgs.grocy}/config-dist.php"; to = "/config/config.php"; } ];
        }}/bin/grocy-server" ];
      };
      wallabag = {
        pkg = pkgs.wallabag; # 2.6.14 (webroot: web/) — WALLABAG_DATA env.
        port = 80;
        volumes = [ "/config" ];
        extraContents = [ phpWithExts ];
        extraEnv = [ "WALLABAG_DATA=/config" ];
        cmd = [ "${mkPhpServer {
          name = "wallabag-server";
          docroot = "${pkgs.wallabag}/web";
          port = 80;
          dirs = [ "/config" ];
          seed = [ { from = "${pkgs.wallabag}/app"; to = "/config/app"; } ];
        }}/bin/wallabag-server" ];
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
            value = mkImage {
              pname = name;
              pkg = apps.${name}.pkg;
              port = apps.${name}.port;
              volumes = apps.${name}.volumes;
              cmdArgs = apps.${name}.cmdArgs or [ ];
              extraEnv = apps.${name}.extraEnv or [ ];
              cmd = apps.${name}.cmd or null;
              extraContents = apps.${name}.extraContents or [ ];
              workdir = apps.${name}.workdir or null;
            };
          }) (builtins.attrNames apps)));
  };
}