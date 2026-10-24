# BLOCKED: python3.12-anyio-4.14.2 uncached + failing tests at this rev.
# Re-enable on a rev bump or with a doCheck=false override.
#
# To re-enable: rename this file to `spoolman.nix` and use:
#    { pkgs, ... }: {
#     pkg = pkgs.spoolman;
#     port = 7912;
#     volumes = [ ];
#   }
#
# (Files with a leading "_" are skipped by the apps discovery in flake.nix.)
