#!/usr/bin/env bash
# Boot-test the published nix images locally with docker.
# Runs each image with temp volumes + baked env and checks its health endpoint.
# Usage: bash scripts/boot-test.sh
set -u
BASE="$(mktemp -d)"; trap 'rm -rf "$BASE"' EXIT

# gatus refuses to boot without a config file. In the cluster the Gatus RGD
# generates one; seed a minimal stand-in (same storage block) for the local
# test, mounted via the volumes machinery below.
mkdir -p "$BASE/gatus/config"
cat > "$BASE/gatus/config/config.yaml" <<'EOF'
storage:
  type: sqlite
  path: /data/gatus.db
endpoints:
  - name: gatus
    url: http://localhost:8080/health
    interval: 60s
    conditions:
      - "[STATUS] == 200"
EOF

# app|tag|containerPort|hostPort|healthPath|volumes(space-sep)|extra docker run args
CASES=(
"audiobookshelf|2.37.1|80|19001|/healthcheck|/config /audiobooks|"
"navidrome|0.64.2|4533|19002|/ping|/data /music|-e ND_MUSICFOLDER=/music"
"kavita|0.9.1.4|5000|19003|/api/Health|/kavita/config /media|"
"jellyfin|12.2|8096|19004|/health|/config /media /cache|"
"hister|0.20.0|4433|19005|/api/config|/hister/search-data /hister/data|-e HISTER__SERVER__BASE_URL=http://localhost:19005"
"writefreely|0.17.2|8080|19006|/|/data|"
"gatus|5.37.0|8080|19010|/health|/config /data|"
"freshrss|1.30.1|8080|19007|/|/data /extensions|"
"grocy|4.7.1|8080|19008|/|/config|"
"wallabag|2.6.14|8080|19009|/|/config|"
)

printf "%-14s %-6s %-8s %-9s %s\n" APP HTTP RUNNING USER HEALTH
for c in "${CASES[@]}"; do
  IFS='|' read -r app tag cport hport health vols extra <<<"$c"
  img="ghcr.io/zunin/$app:$tag"
  docker pull -q "$img" >/dev/null 2>&1 || { echo "$app pull FAILED"; continue; }
  volargs=(); for v in $vols; do d="$BASE/$app$v"; mkdir -p "$d"; volargs+=(-v "$d:$v"); done
  name="boot-$app"; docker rm -f "$name" >/dev/null 2>&1
  docker run -d --name "$name" -p "$hport:$cport" "${volargs[@]}" $extra "$img" >/dev/null 2>&1
  code="000"
  for _ in $(seq 1 20); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$hport$health" 2>/dev/null)
    [ "$code" != "000" ] && break
    sleep 1
  done
  running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "?")
  user=$(docker inspect -f '{{.Config.User}}' "$img" 2>/dev/null)
  printf "%-14s %-6s %-8s %-9s %s\n" "$app" "$code" "$running" "$user" "$health"
  [ "$code" = "000" ] && { echo "  --- last logs ($app) ---"; docker logs "$name" 2>&1 | tail -5 | sed 's/^/  /'; }
  docker rm -f "$name" >/dev/null 2>&1
done
