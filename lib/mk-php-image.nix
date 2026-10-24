# PHP support + builder for PHP web apps (grocy, wallabag, freshrss).
#
# PHP web apps have no runnable binary. Serve them with php-fpm + Caddy
# (FastCGI) as a non-root user on an unprivileged port (the fleet Service
# maps :80 -> the container port).
#
# Takes { pkgs, nixpkgsRev } (the flake input's locked revision, used for
# the dev.zunin.nixpkgs-revision label) and returns:
#   mkPhpExts, php84Patched, php85Patched, phpWithExts, mkPhpImage
{ pkgs, nixpkgsRev }:
let
  lib = pkgs.lib;

  mkPhpExts = php: php.withExtensions ({ enabled, all }:
    # Skip extension test suites: several bundled OOM tests assert memory-limit
    # behaviour that varies with the build environment (they failed under the
    # local build sandbox for the 8.4.27 security backport). The php
    # interpreter itself is still built and tested normally.
    map (p: p.overrideAttrs (_: { doCheck = false; })) (
      enabled ++ (map (n: all.${n})
        (lib.filter (n: all ? n)
          [ "pdo_sqlite" "sqlite3" "intl" "gd" "curl" "zip" "exif" "opcache" ]))));
  # Default PHP (8.4). Apps needing a newer PHP pass `php = mkPhpExts php85Patched`.
  #
  # TEMPORARY security backport (2026-10-21): PHP released 8.3.36 / 8.4.27 /
  # 8.5.12 fixing CVE-2026-109618 and CVE-2026-109619 (affects <= 8.4.26 /
  # 8.5.11). nixpkgs master has the bump (PR #576853) but nixos-unstable has
  # not advanced yet. Drop these overrides and go back to pkgs.php /
  # pkgs.php85 once unstable includes the bump (the weekly flake-update
  # workflow will otherwise pick it up anyway).
  php84Patched = pkgs.php84.overrideAttrs (_: {
    version = "8.4.27";
    src = pkgs.fetchurl {
      url = "https://www.php.net/distributions/php-8.4.27.tar.bz2";
      hash = "sha256-slMKh3xyL0sIyeF0owywi6wrfhkD7m6eMV8KqfX4LCQ=";
    };
  });
  php85Patched = pkgs.php85.overrideAttrs (_: {
    version = "8.5.12";
    src = pkgs.fetchurl {
      url = "https://www.php.net/distributions/php-8.5.12.tar.bz2";
      hash = "sha256-/7YO3EN87WO1E35JhNs3moERxQBJxxFRDYuVgnfvwag=";
    };
  });
  phpWithExts = mkPhpExts php84Patched;

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
        # nixpkgs revision the image was built from (custom namespace: the
        # standard revision label would make Renovate treat upstream release
        # notes as nixpkgs commits).
        "dev.zunin.nixpkgs-revision" = nixpkgsRev;
      };
    };
  };
in
{
  inherit mkPhpExts php84Patched php85Patched phpWithExts mkPhpImage;
}
