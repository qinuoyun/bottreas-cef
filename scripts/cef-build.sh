#!/usr/bin/env bash
# Builds a CEF "minimal" binary distribution from source with the proprietary
# codecs (H.264, AAC, HEVC) that the official builds at cef-builds.spotifycdn.com
# leave out. Used by .github/workflows/cef-platform.yml, where one build is a
# chain of jobs. Each command is one stage of such a job:
#
#   prepare                 pick the toolchain, free disk space on the runner
#   fetch                   check out CEF and Chromium, patch, configure (job 1)
#   restore                 unpack the tree the previous job packed (jobs 2+)
#   build                   run ninja until the job's time is nearly up
#   distrib                 make cef_binary_<version>_<platform>_minimal.tar.bz2
#   save                    pack the tree for the next job
#   publish                 upload the distributions to the release
#   drop-artifacts <prefix> delete this run's artifacts named <prefix>...
#
# Settings come from the environment: PLATFORM (macosarm64, macosx64 or
# windows64), CEF_VERSION (required), CEF_BRANCH and CEF_COMMIT (read from
# CEF_VERSION when empty), GN_DEFINES_EXTRA, CEF_PGO, XCODE_VERSION, JOB_START,
# BUILD_UNTIL_MINUTE.
#
# Adapted from scripts/cef-codecs.sh in https://github.com/dpfaffenbauer/OpenArch
# (MIT, Copyright (c) 2026 Dominik Pfaffenbauer), which builds macOS arm64 only.
# Written for bash 3.2 (macOS runners) and Git Bash (Windows runners).
set -euo pipefail

PLATFORM="${PLATFORM:?PLATFORM is required: macosarm64, macosx64 or windows64}"
CEF_VERSION="${CEF_VERSION:?CEF_VERSION is required}"
SHORT_VERSION="${CEF_VERSION%%+*}"                 # 156.0.31
CHROMIUM_VERSION="${CEF_VERSION##*+chromium-}"     # 156.0.8078.100
# CEF names its release branches after Chromium's build number (8078) ...
CEF_BRANCH="${CEF_BRANCH:-$(echo "$CHROMIUM_VERSION" | cut -d. -f3)}"
# ... and its versions after the commit ("+ge603d97+").
commit="${CEF_VERSION#*+g}"
CEF_COMMIT="${CEF_COMMIT:-${commit%%+*}}"

case "$PLATFORM" in
  macosarm64) ARCH_FLAG=--arm64-build; OUT_CONFIG=Release_GN_arm64; ARCH_ENV=CEF_ENABLE_ARM64 ;;
  macosx64) ARCH_FLAG=--x64-build; OUT_CONFIG=Release_GN_x64; ARCH_ENV=CEF_ENABLE_AMD64 ;;
  windows64) ARCH_FLAG=--x64-build; OUT_CONFIG=Release_GN_x64; ARCH_ENV=CEF_ENABLE_AMD64 ;;
  *) echo "Unknown PLATFORM $PLATFORM" >&2; exit 2 ;;
esac
IS_WINDOWS=false
if [[ "$PLATFORM" == windows64 ]]; then IS_WINDOWS=true; fi

# The same path in every job: the build files refer to it. On Windows a short
# path on the roomiest drive keeps clear of the 260-character path limit.
if $IS_WINDOWS; then WORK="${CEF_WORK:-/c/cef}"; else WORK="$HOME/cef"; fi
SRC="$WORK/chromium/src"
OUT="$SRC/out/$OUT_CONFIG"
NINJA="$SRC/third_party/ninja/ninja"
XCODE_APP=/Applications/Xcode-cef.app
STATE_DIR="${RUNNER_TEMP:-/tmp}/cef-state"
DIST_DIR="${RUNNER_TEMP:-/tmp}/cef-distrib"
DIST_NAME="cef_binary_${CEF_VERSION}_${PLATFORM}_minimal"
RELEASE_TAG="cef-${SHORT_VERSION}-codecs"
PY=python3
if $IS_WINDOWS; then PY=python; fi

# Test data CEF never builds; dropped after configuring to shrink the tree
# every job packs and unpacks (see prune).
PRUNE_DIRS="third_party/blink/web_tests chrome/test/data content/test/data"

export PATH="$WORK/depot_tools:$PATH"
if $IS_WINDOWS; then
  # Use the Visual Studio on the runner, not Google's internal toolchain package.
  export DEPOT_TOOLS_WIN_TOOLCHAIN=0 GYP_MSVS_VERSION=2022
  vs="$("/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" -latest -property installationPath 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "$vs" ]]; then export vs2022_install="$vs" GYP_MSVS_OVERRIDE_PATH="$vs"; fi
fi

output() {
  echo "$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

fail() {
  echo "::error::$*" >&2
  exit 1
}

disk() {
  df -h "$(dirname "$WORK")" | awk 'NR == 2 { print $4 " free of " $2 }'
}

cpus() {
  if $IS_WINDOWS; then echo "${NUMBER_OF_PROCESSORS:-4}"; else sysctl -n hw.ncpu; fi
}

sha256() {
  if command -v shasum > /dev/null; then shasum -a 256 "$@"; else sha256sum "$@"; fi
}

tar_cmd() {
  if command -v gtar > /dev/null; then gtar "$@"; else tar "$@"; fi
}

# The GN args of the build. CEF adds what it requires itself (gn_args.py:
# is_component_build=false, enable_widevine and so on); these are on top.
gn_defines() {
  local defines="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome"
  defines="$defines symbol_level=0"
  # A newer SDK than Chromium was tested with must not stop the build on a
  # deprecation warning.
  defines="$defines treat_warnings_as_errors=false"
  # Official builds use PGO profiles; without them they must be turned off.
  if [[ "${CEF_PGO:-true}" != true ]]; then defines="$defines chrome_pgo_phase=0"; fi
  # Later values win, so the workflow input can override any of the above.
  echo "$defines ${GN_DEFINES_EXTRA:-}"
}

prepare() {
  echo "Disk: $(disk)"
  if $IS_WINDOWS; then
    check_windows_sdk
  else
    # Spotlight would index the tens of GB the build writes.
    sudo mdutil -a -i off > /dev/null 2>&1 || true
    select_xcode
    free_disk_mac
  fi
  echo "Disk: $(disk)"
}

# Chromium needs the "Debugging Tools for Windows" of the Windows SDK
# (dbghelp.dll), which is an optional SDK feature.
check_windows_sdk() {
  local kits="/c/Program Files (x86)/Windows Kits/10"
  ls "$kits/Include" || true
  if [[ -f "$kits/Debuggers/x64/dbghelp.dll" ]]; then
    echo "Debugging Tools for Windows: present"
    return
  fi
  echo "::warning::Debugging Tools for Windows are missing; installing them"
  curl -fsSL -o "$RUNNER_TEMP/winsdksetup.exe" "https://go.microsoft.com/fwlink/?linkid=2272610"
  "$RUNNER_TEMP/winsdksetup.exe" //features OptionId.WindowsDesktopDebuggers //quiet //norestart
  [[ -f "$kits/Debuggers/x64/dbghelp.dll" ]] || fail "Could not install the Debugging Tools for Windows."
}

# Keeps one Xcode, always at $XCODE_APP: compile commands contain the SDK
# path, and a different path in a later job would make ninja rebuild all.
select_xcode() {
  local want="/Applications/Xcode_${XCODE_VERSION:-}.app" keep app
  if [[ -z "${XCODE_VERSION:-}" || ! -d "$want" ]]; then
    want="$(dirname "$(dirname "$(xcode-select -p)")")"
    echo "::warning::Xcode ${XCODE_VERSION:-} is not on this image, using $want."
  fi
  keep="$(cd "$want" && pwd -P)"
  for app in /Applications/Xcode*.app; do
    if [[ -L "$app" ]]; then
      sudo rm -f "$app"
    elif [[ "$app" != "$keep" ]]; then
      echo "Deleting $app"
      sudo rm -rf "$app"
    fi
  done
  sudo mv "$keep" "$XCODE_APP"
  sudo xcode-select --switch "$XCODE_APP"
  xcodebuild -version
}

# Simulators, the Android and .NET SDKs and other tool caches: tens of GB
# Chromium does not need. Best effort; a failure here only costs space.
free_disk_mac() {
  local tool
  xcrun simctl delete all > /dev/null 2>&1 || true
  sudo xcrun simctl runtime delete all > /dev/null 2>&1 || true
  sudo rm -rf "${ANDROID_HOME:-$HOME/Library/Android/sdk}" "$HOME/.dotnet"
  # Keeps Python, which actions/setup-python installs there.
  for tool in "${RUNNER_TOOL_CACHE:-$HOME/hostedtoolcache}"/*; do
    if [[ "$(basename "$tool")" != Python ]]; then sudo rm -rf "$tool"; fi
  done
}

fetch() {
  echo "CEF $CEF_VERSION for $PLATFORM: branch $CEF_BRANCH, commit $CEF_COMMIT"
  mkdir -p "$WORK"
  curl -fsSL -o "$WORK/automate-git.py" \
    "https://raw.githubusercontent.com/chromiumembedded/cef/$CEF_BRANCH/tools/automate/automate-git.py"

  local pgo=""
  if [[ "${CEF_PGO:-true}" == true ]]; then pgo="--with-pgo-profiles"; fi
  # CEF's own checkout tool: depot_tools, CEF at the commit, the Chromium
  # version CEF names in CHROMIUM_BUILD_COMPATIBILITY.txt (without git
  # history, which saves tens of GB) and Chromium's hooks (clang, rust ...).
  # It would also build, but cannot stop and resume, so that is done below.
  $PY "$WORK/automate-git.py" --download-dir="$WORK" \
    --depot-tools-dir="$WORK/depot_tools" --branch="$CEF_BRANCH" \
    --checkout="$CEF_COMMIT" --no-chromium-history $pgo \
    $ARCH_FLAG --no-debug-build --no-build --no-distrib
  # automate-git.py works on its own clone; src/cef is a copy of it.
  rm -rf "$WORK/cef"

  # The version is computed from git, as make_distrib.py will do; it names
  # the archive, so a mismatch is better found now than in a day.
  local actual
  actual="$($PY "$SRC/cef/tools/cef_version.py" current | tr -d '\r')"
  [[ "$actual" == "$CEF_VERSION" ]] || fail "The checkout is CEF $actual, not $CEF_VERSION."

  # What automate-git.py does before it builds: translate CEF's API files,
  # apply CEF's patches to Chromium, write args.gn and run gn gen. Only the
  # one Release configuration.
  (cd "$SRC/cef" && env GN_DEFINES="$(gn_defines)" GN_OUT_CONFIGS="$OUT_CONFIG" \
    "$ARCH_ENV=1" $PY tools/gclient_hook.py)
  cat "$OUT/args.gn"
  grep -q 'proprietary_codecs *= *true' "$OUT/args.gn" || fail "args.gn lacks proprietary_codecs=true."

  prune
  echo "Disk: $(disk)"
}

# Moves PRUNE_DIRS out of the tree unless gn read files from them, then lets
# ninja check (dry run) that the build needs nothing that went with them.
# If it does, everything is put back.
prune() {
  local trash="$WORK/pruned" dir
  mkdir -p "$trash"
  for dir in $PRUNE_DIRS; do
    [[ -d "$SRC/$dir" ]] || continue
    if grep -qF "../../$dir/" "$OUT/build.ninja.d"; then
      echo "Keeping $dir: gn reads files from it"
      continue
    fi
    mkdir -p "$trash/$(dirname "$dir")"
    mv "$SRC/$dir" "$trash/$dir"
  done
  if "$NINJA" -C "$OUT" -n cefclient > /dev/null; then
    rm -rf "$trash"
    return
  fi
  echo "::warning::The build needs files from $PRUNE_DIRS; keeping them."
  for dir in $PRUNE_DIRS; do
    if [[ -d "$trash/$dir" ]]; then mv "$trash/$dir" "$SRC/$dir"; fi
  done
  rm -rf "$trash"
}

# Builds cefclient, which make_distrib.py takes the framework or DLLs from,
# until BUILD_UNTIL_MINUTE minutes after JOB_START. Sets the step output
# "status" to "finished", or to "running" when the next job has to carry on.
build() {
  export DEPOT_TOOLS_UPDATE=0
  local stop budget stopped="${RUNNER_TEMP:-/tmp}/ninja-stopped" ninja_pid watchdog rc=0
  stop=$(( ${JOB_START:?JOB_START is required} + ${BUILD_UNTIL_MINUTE:-300} * 60 ))
  budget=$(( stop - $(date +%s) ))
  rm -f "$stopped"
  if (( budget < 600 )); then
    echo "Less than 10 minutes left, leaving the build to the next job"
    output status=running
    return
  fi
  echo "Building for at most $(( budget / 60 )) minutes. Disk: $(disk)"

  # Ninja is resumable by design: when it is stopped, the next job's ninja
  # redoes only the unfinished steps. A watchdog stops it when the time is up.
  NINJA_STATUS="[%p %f/%t %e] " "$NINJA" -C "$OUT" -j "$(cpus)" cefclient &
  ninja_pid=$!
  (
    sleep "$budget"
    kill -0 "$ninja_pid" || exit 0
    touch "$stopped"
    kill -TERM "$ninja_pid"
    if $IS_WINDOWS; then
      # Git Bash's kill does not reach the native ninja.exe and its compilers.
      taskkill //F //T //IM ninja.exe > /dev/null 2>&1 || true
    fi
    # Ninja exits within seconds; this is only the backstop.
    sleep 600
    kill -KILL "$ninja_pid"
  ) 2> /dev/null &
  watchdog=$!
  wait "$ninja_pid" || rc=$?
  kill "$watchdog" 2> /dev/null || true
  wait "$watchdog" 2> /dev/null || true

  echo "Disk: $(disk)"
  if [[ -f "$stopped" ]]; then
    output status=running
  elif (( rc == 0 )); then
    output status=finished
  else
    fail "ninja failed with exit code $rc."
  fi
}

# Makes the minimal distribution, the same kind cef-builds.spotifycdn.com
# serves, and puts it with its SHA-256 into DIST_DIR.
distrib() {
  export DEPOT_TOOLS_UPDATE=0
  local out="$WORK/distrib"
  rm -rf "$out" "$DIST_DIR"
  mkdir -p "$out" "$DIST_DIR"
  (cd "$SRC/cef/tools" && CEF_ARCHIVE_FORMAT=tar.bz2 $PY make_distrib.py \
    --output-dir="$out" --ninja-build $ARCH_FLAG --minimal --no-symbols --no-docs)
  [[ -f "$out/$DIST_NAME.tar.bz2" ]] || fail "Expected $DIST_NAME.tar.bz2, got: $(ls "$out")"
  mv "$out/$DIST_NAME.tar.bz2" "$DIST_DIR/"
  (cd "$DIST_DIR" && sha256 "$DIST_NAME.tar.bz2" > "$DIST_NAME.tar.bz2.sha256")
  cat "$DIST_DIR/$DIST_NAME.tar.bz2.sha256"
  ls -lh "$DIST_DIR"
}

# Packs WORK into 1 GB parts in STATE_DIR. Each file is deleted as soon as it
# is packed, so the tree and its archive never need the disk at once.
save() {
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  tar_cmd -C "$(dirname "$WORK")" --remove-files -cf - "$(basename "$WORK")" |
    zstd -q -T0 -10 --long=27 |
    split -b 1024m - "$STATE_DIR/cef.tar.zst.part-"
  (cd "$STATE_DIR" && sha256 cef.tar.zst.part-* > SHA256SUMS)
  du -sh "$STATE_DIR"
}

# Unpacks what save packed. Each part is deleted once it has been read.
restore() {
  local part
  (cd "$STATE_DIR" && sha256 -c SHA256SUMS)
  mkdir -p "$(dirname "$WORK")"
  for part in "$STATE_DIR"/cef.tar.zst.part-*; do
    cat "$part"
    rm "$part"
  done | zstd -d -q --long=27 | tar_cmd -C "$(dirname "$WORK")" -xf -
  [[ -d "$OUT" ]] || fail "The unpacked tree has no $OUT."
  echo "Disk: $(disk)"
}

# Creates the release (or adds to it) with every distribution in DIST_DIR and
# its SHA-256. DIST_DIR holds one sub-directory per platform here.
publish() {
  local files=() file notes
  while IFS= read -r file; do files+=("$file"); done < <(find "$DIST_DIR" -name 'cef_binary_*_minimal.tar.bz2*' | sort)
  (( ${#files[@]} > 0 )) || fail "No distributions in $DIST_DIR."
  for file in "${files[@]}"; do
    if [[ "$file" == *.sha256 ]]; then (cd "$(dirname "$file")" && sha256 -c "$(basename "$file")"); fi
  done
  notes="CEF $CEF_VERSION, minimal distributions built from source with the proprietary codecs (H.264, AAC, HEVC) that the official builds leave out.

GN_DEFINES: $(gn_defines)

Built by $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  if gh release view "$RELEASE_TAG" > /dev/null 2>&1; then
    gh release upload "$RELEASE_TAG" "${files[@]}" --clobber
  else
    gh release create "$RELEASE_TAG" "${files[@]}" --target "$GITHUB_SHA" \
      --title "CEF $SHORT_VERSION with proprietary codecs" --notes "$notes"
  fi
  # GitHub renames some characters in asset names; "+" must survive.
  for file in "${files[@]}"; do
    gh release view "$RELEASE_TAG" --json assets --jq '.assets[].name' |
      grep -qxF "$(basename "$file")" || fail "The release has no asset named $(basename "$file")."
  done
  echo "Published $RELEASE_TAG"
}

# Deletes this workflow run's artifacts whose name starts with $1.
drop_artifacts() {
  local prefix="${1:?usage: cef-build.sh drop-artifacts <name prefix>}" id
  gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts" \
    --jq ".artifacts[] | select(.name | startswith(\"$prefix\")) | .id" |
    while read -r id; do
      gh api -X DELETE "repos/$GITHUB_REPOSITORY/actions/artifacts/$id"
      echo "Deleted artifact $id"
    done
}

case "${1:-}" in
  prepare) prepare ;;
  fetch) fetch ;;
  restore) restore ;;
  build) build ;;
  distrib) distrib ;;
  save) save ;;
  publish) publish ;;
  drop-artifacts) drop_artifacts "${2:-}" ;;
  *)
    echo "usage: $0 prepare|fetch|restore|build|distrib|save|publish|drop-artifacts <prefix>" >&2
    exit 2
    ;;
esac
