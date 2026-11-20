# CEF with proprietary codecs

Builds of the [Chromium Embedded Framework](https://github.com/chromiumembedded/cef)
with the proprietary codecs (H.264, AAC, HEVC) enabled, for macOS arm64,
macOS x64 and Windows x64. The official builds at
[cef-builds.spotifycdn.com](https://cef-builds.spotifycdn.com/index.html) leave
them out on purpose ([cef#3559](https://github.com/chromiumembedded/cef/issues/3559)).

Each build is the "minimal" binary distribution, under the official file name,
for example `cef_binary_156.0.31+ge603d97+chromium-156.0.8078.100_macosarm64_minimal.tar.bz2`,
published with its SHA-256 as the release `cef-<version>-codecs`.

## How it is built

[`.github/workflows/cef.yml`](.github/workflows/cef.yml), started by hand, runs
one chain of GitHub-hosted jobs per platform
([`cef-platform.yml`](.github/workflows/cef-platform.yml)). Each job builds for
about five hours and hands the build tree to the next, until ninja is done.
[`scripts/cef-build.sh`](scripts/cef-build.sh) does the work with CEF's own
`automate-git.py`, `gclient_hook.py` and `make_distrib.py`. The GN arguments are
CEF's defaults plus:

```
is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome symbol_level=0 treat_warnings_as_errors=false
```

## Licensing

CEF and Chromium are BSD-licensed; Chromium's FFmpeg is LGPL. H.264, AAC and
HEVC are covered by patents in many countries. Whoever distributes these
binaries is responsible for any patent licences that apply to them.
