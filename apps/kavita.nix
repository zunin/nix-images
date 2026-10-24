{ pkgs, ... }:
{
  sourceUrl = "https://github.com/Kareadita/Kavita";
  pkg = pkgs.kavita; # 0.9.1.4
  port = 5000;
  volumes = [ "/kavita/config" "/media" ];
  # Kavita's config dir is <cwd>/config, so cwd must be the parent of the
  # /kavita/config mount (matches the existing PVC / official layout).
  workdir = "/kavita";
}
