{ pkgs, ... }:
{
  sourceUrl = "https://github.com/TwiN/gatus";
  pkg = pkgs.gatus; # 5.37.0
  port = 8080;
  volumes = [ "/data" ];
  # The Gatus RGD (fleet/kro/gatus-rgd.yaml) mounts the generated
  # config at /config via subPath; bake the env so the image also
  # boots standalone (local boot test) without extra args.
  extraEnv = [ "GATUS_CONFIG_PATH=/config" ];
}
