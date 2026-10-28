# nix-images

Builds OCI images for the home cluster from **nixpkgs**, using `dockerTools`.
The fleet repo (`fleet/`) consumes these via `ghcr.io/zunin/<app>:<version>`.

The whole point: one `nixos-unstable` revision drives **both** the base OS
(glibc, openssl, node, ffmpeg) and every app version. A renovate merge of a
`flake.lock` bump re-renders all apps in lockstep — the "stack update" and
"app version" lanes collapse into one.

## Layout

```
flake.nix                  # inputs + wiring; packages output = <app> + <app>-image
lib/mk-image.nix           # shared builder for binary apps
lib/mk-php-image.nix       # php-fpm + Caddy builder (+ PHP extension/patch support)
apps/<name>.nix            # one file per app; "_"-prefixed files are skipped
apps/_spoolman.nix         # blocked apps live here until re-enabled
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
4. **Unchanged builds are neither rebuilt nor pushed.** Every image carries
   a `dev.zunin.build-fingerprint` label (builder file hash + nixpkgs rev +
   package store path + all image params). The fingerprint is computed at
   eval time, so when the published tag has the same fingerprint the
   workflow skips the build **and** the push — no new `<version>-<run>` tag
   and no duplicate attestations. This also absorbs nondeterministic
   rebuilds (php/npm produce different bytes from identical inputs). PRs
   always build; `workflow_dispatch` forces a rebuild.

Because Nix is content-addressed, a nominal "rebuild all" only produces new
digests for apps whose closure actually changed — unchanged apps rebuild to
byte-identical images.

## Adding an app

1. Create `apps/<name>.nix` returning the app attrs (nixpkgs package, port,
   volumes) — see `apps/navidrome.nix` for a minimal example. PHP apps use
   `mkPhpImage` (see `apps/grocy.nix`). Files with a leading `_` are skipped.
2. Nothing else — the CI matrix is derived from the flake (`prepare` job
   evaluates the `packages` outputs). Update the `workflow_dispatch` dropdown
   only if you want the app in the manual-build picker.
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

- Rebuilds are gated on the `dev.zunin.build-fingerprint` label, so a
  no-op push (docs/workflow-only change) costs only the eval plus one
  registry lookup per app — no builds, no pushes, no attestations.

- App-version timing rides nixpkgs (`unstable` ≈ days–weeks behind upstream).
- Some nixpkgs wrappers ignore env and only read CLI flags — pass the correct
  invocation via an app's `cmdArgs`/`extraEnv` in `flake.nix`. audiobookshelf is
  the example: `--port 80 --config /config --metadata /metadata` +
  `ROUTER_BASE_PATH=/` (defaults would be 8000, nested config, subpath).
- Size varies wildly by closure: audiobookshelf pulls nixpkgs' `ffmpeg-full`
  (gtk/gstreamer/mesa/opencv) → ~1.9 GB, vs ~124 MB official. Overriding to
  `ffmpeg-headless` needs a local wrapper (the nixpkgs package hardcodes it).
- The `renovate` image needs a **writable rootfs**: its `nix flake update`
  fetches tarballs into `/nix/store` and inits the nix db under `/nix/var/nix`
  (see `apps/renovate.nix`). Don't set `readOnlyRootFilesystem` on that
  CronJob; the store *directory* is chowned to UID 1000 at build time via
  `extraFakeRootCommands`, existing store paths stay read-only.
- Some nixpkgs packages are "raw files" (e.g. wallabag) and need a wrapper
  image — so far both apps here are straight `dockerTools` jobs.
- The image `name` uses the `owner` placeholder; CI retags to the GitHub repo
  owner. Update it if you build/push outside CI.

## CVE accuracy (Grype)

Grype matches nix packages against NVD by CPE, which is noisy: many NVD entries
have unbounded (`*`) version ranges or are disputed, so they match modern nix
packages. Two mechanisms keep the Security tab honest:

- **`openvex.json`** (OpenVEX) — `not_affected` statements with justifications,
  fed to Grype via `--vex`. Products use versionless purls (`pkg:nix/<name>`),
  which Grype matches across versions (CPE product ids do NOT match), so entries
  survive rev bumps. Add suppressions here (reviewable in git) instead of
  dismissing alerts in the UI.
- **Exposure view** (not an action-queue): we keep *all* post-VEX findings,
  including real-but-unfixable ones, sorted by `risk` (EPSS/KEV-aware). The log
  line reports total + KEV + high-EPSS counts. (`--only-fixed` would instead
  show just the upgradeable subset — deliberately not used.)

App-layer findings (npm/go/python, from lockfiles/buildinfo) are reliable; the
OS/closure CPE layer is the noisy part. Triage by `knownExploited` (KEV) / EPSS.