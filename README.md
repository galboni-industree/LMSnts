# NTS Radio — Lyrion Music Server plugin

Adds the two live **NTS** channels (NTS 1 / NTS 2) to Lyrion Music Server (LMS)
and shows the **currently airing show title + artwork** on the Now Playing
screen, kept up to date automatically as shows rotate.

The audio is the public NTS MP3 stream (256 kbps); the added value is the
metadata, fetched from the public NTS live API.

## Layout

```
src/NTSRadio/                 # <- this folder is deployed to .../Plugins/NTSRadio
  install.xml                 # plugin manifest
  Plugin.pm                   # menu (OPML) + metadata provider + 60s poller
  strings.txt                 # EN/IT strings
  HTML/EN/plugins/NTSRadio/html/icon.png   # official NTS logo (960x960)
preflight.sh                  # read-only environment checks (changes nothing)
deploy.sh                     # validate + backup + deploy + restart + log check
undeploy.sh                   # clean removal, back to a pristine system
PROCEDURA.md                  # step-by-step install guide (IT) with a Plan B each step
samples/live.json             # reference fixture of the NTS /api/v2/live response
```

## How it works

Three pieces, all in `Plugin.pm`:

1. **Menu (OPML)** — `Slim::Plugin::OPMLBased` exposes "NTS Radio" under the
   Radio menu with two playable `audio` items pointing at the canonical stream
   URLs.
2. **Metadata provider** — `Slim::Formats::RemoteMetadata->registerProvider`,
   matched against `ntslive.net` **and** `radiomast.io` (the edge host the
   canonical URL redirects to). It answers `getMetadataFor` purely from an
   in-memory cache — never any network I/O on the server thread.
3. **Poller** — every 60s a single async GET to `/api/v2/live` refreshes the
   cache for both channels and, when a show changes, fires `newmetadata` for
   any player tuned to that channel so the screen updates.

## Deploy (on the LMS device)

This repo holds the **sources**. Deployment and the acceptance tests run on the
target box (aarch64 / DietPi / LMS 9.1.1), not in CI. Full step-by-step guide
with a Plan B for every critical step: see [`PROCEDURA.md`](PROCEDURA.md).

```bash
git clone -b claude/nts-radio-lms-plugin-eWd59 https://github.com/galboni-industree/LMSnts.git ~/nts-plugin
cd ~/nts-plugin
./preflight.sh     # read-only checks — changes nothing
./deploy.sh        # validate + backup + deploy to .../Plugins/NTSRadio + restart
```

Then in the LMS web UI: **Settings → Manage Plugins**, enable **NTS Radio**,
restart. For debugging set **Settings → Advanced → Logging → `plugin.ntsradio`**
to `DEBUG`. To remove cleanly: `./undeploy.sh`.

## Notes / scope

* No new CPAN dependencies — only modules shipped with LMS (`Slim::*`,
  `JSON::XS`, `IO::Socket::SSL`).
* No transcoding, no protocol handler, no settings page, no submenus.
* `icon.png` is the official square NTS logo (white-on-black). It doubles as the
  cover-art fallback when the API provides no image.
* The API signatures marked **VERIFY** in the build brief should be confirmed
  against the LMS source installed on the device
  (`/usr/share/squeezeboxserver/Slim/...`) before relying on edge cases.
