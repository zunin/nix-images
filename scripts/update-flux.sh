#!/usr/bin/env bash
# Bot-packaged Renovate task: generate manifests only, never install in a cluster.
set -euo pipefail

if [[ $# != 1 ]] || [[ ! "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Usage: update-flux v<major>.<minor>.<patch>' >&2
  exit 2
fi

version="$1"
output=flux-system/gotk-components.yaml
if [[ ! -f "$output" ]]; then
  echo "Expected $output in the repository working directory" >&2
  exit 2
fi

case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo 'Unsupported Flux CLI architecture' >&2; exit 2 ;;
esac

umask 077
work_dir=$(mktemp -d)
manifest=''
cleanup() {
  rm -rf "$work_dir"
  if [[ -n "$manifest" ]]; then
    rm -f "$manifest"
  fi
}
trap cleanup EXIT
manifest=$(mktemp "${output}.XXXXXX")

# A matching CLI is necessary: Flux refuses cross-minor install/export requests.
asset="flux_${version#v}_linux_${arch}.tar.gz"
release="https://github.com/fluxcd/flux2/releases/download/$version"
curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 120 \
  --proto '=https' --proto-redir '=https' \
  "$release/$asset" --output "$work_dir/$asset"
curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 120 \
  --proto '=https' --proto-redir '=https' \
  "$release/flux_${version#v}_checksums.txt" --output "$work_dir/checksums.txt"
checksum=$(awk -v name="$asset" '$2 == name { print $1 }' "$work_dir/checksums.txt")
if [[ ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
  echo "Missing or ambiguous checksum for $asset" >&2
  exit 1
fi
(
  cd "$work_dir"
  printf '%s  %s\n' "$checksum" "$asset" | sha256sum --check --strict
)
tar --extract --gzip --file "$work_dir/$asset" --directory "$work_dir" flux

"$work_dir/flux" install --version="$version" \
  --components=source-controller,kustomize-controller,helm-controller,notification-controller \
  --export > "$manifest"
test -s "$manifest"
grep -Fxq "# Flux Version: $version" "$manifest"
grep -Fq 'kind: CustomResourceDefinition' "$manifest"
grep -Fq 'image: ghcr.io/fluxcd/' "$manifest"
chmod --reference="$output" "$manifest"
mv "$manifest" "$output"
echo "Regenerated $output for Flux $version"
