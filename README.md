# nix-images

Builds OCI images for the home cluster from **nixpkgs**, using `dockerTools`.
The fleet repo (`fleet/`) consumes these via `ghcr.io/zunin/<app>:<version>`.

The whole point: one `nixos-unstable` revision drives **both** the base OS
(glibc, openssl, node, ffmpeg) and every app version. A renovate merge of a
`flake.lock` bump re-renders all apps in lockstep — the "stack update" and
"app version" lanes collapse into one.

## Layout

```
flake.nix                  # one entry per app in `apps`; mkImage builds them
flake.lock                 # pins the nixpkgs revision (generated, commit it)
renovate.json5             # auto-merges flake.lock bumps (nix manager)
.github/workflows/build-images.yml
```

## How the update flow works

1. renovate bumps the `nixpkgs` input (`flake.lock`) → PR → merge to `main`.
2. The workflow rebuilds every app against the new revision, pushes:
   - `ghcr.io/<owner>/<app>:<version>` — **mutable**; the digest changes on
     every base/OS patch, the version string does not.
   - `ghcr.io/<owner>/<app>:<version>-<run_number>` — **immutable**,
     provenance record.
3. In `fleet/`, pin `image: <app>` + `tag: <version>@sha256:<digest>`:
   - renovate **auto-merges** digest changes (base/OS lane),
   - opens a **PR** when the version tag changes (app-version lane).

Because Nix is content-addressed, a nominal "rebuild all" only produces new
digests for apps whose closure actually changed — unchanged apps rebuild to
byte-identical images.

## Adding an app

1. Add an entry to `apps` in `flake.nix` (nixpkgs package, port, volumes).
2. Add the app name to the workflow matrix.
3. In `fleet/`, point the `Application` CR at `ghcr.io/<owner>/<app>` with a
   digest-pinned tag, and extend the renovate custom manager to data-source
   the GHCR package.

## Local build & smoke test

Run once (needs `nix` with flake support):

```bash
nix flake lock --accept-flake-config   # creates flake.lock; commit it
nix build .#packages.x86_64-linux.audiobookshelf-image
docker load < result
mkdir -p /tmp/abconfig /tmp/abaudio && sudo chown 1000:1000 /tmp/abconfig /tmp/abaudio
docker run --rm -p 80:80 -v /tmp/abconfig:/config -v /tmp/abaudio:/audiobooks \
  ghcr.io/zunin/audiobookshelf:2.37.1
```

## Pilot checklist (audiobookshelf → navidrome)

- [ ] Build + load + `docker run`; confirm transcoding works (ffmpeg is in the closure)
- [ ] Port matches the `Application` CR (`80` for audiobookshelf, `4533` navidrome)
- [ ] App finds its config dir (`/config`) at UID 1000; `kro` template provides `fsGroup`
- [ ] `syft`/`trivy` scan on a pushed image; compare CVE recall vs the official one
- [ ] In `fleet/`: digest-pinned tag + renovate digest automerge; app version → PR
- [ ] Confirm a `flake.lock` bump rolls the mutable tag and the fleet picks it up

## Caveats

- App-version timing rides nixpkgs (`unstable` ≈ days–weeks behind upstream).
- Some nixpkgs wrappers ignore env and only read CLI flags — pass the correct
  invocation via an app's `cmdArgs`/`extraEnv` in `flake.nix`. audiobookshelf is
  the example: `--port 80 --config /config --metadata /metadata` +
  `ROUTER_BASE_PATH=/` (defaults would be 8000, nested config, subpath).
- Size varies wildly by closure: audiobookshelf pulls nixpkgs' `ffmpeg-full`
  (gtk/gstreamer/mesa/opencv) → ~1.9 GB, vs ~124 MB official. Overriding to
  `ffmpeg-headless` needs a local wrapper (the nixpkgs package hardcodes it).
- Some nixpkgs packages are "raw files" (e.g. wallabag) and need a wrapper
  image — so far both apps here are straight `dockerTools` jobs.
- The image `name` uses the `owner` placeholder; CI retags to the GitHub repo
  owner. Update it if you build/push outside CI.