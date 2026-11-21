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
# path keeps clear of the 260-character path limit, and prepare puts it on the
# drive with the most room (CEF_WORK, through GITHUB_ENV).
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
  # Chromium 156 is built with Visual Studio 2026 (vs_toolchain.py), the one on the image.
  export DEPOT_TOOLS_WIN_TOOLCHAIN=0 GYP_MSVS_VERSION=2026
  vs="$("/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" -latest -property installationPath 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "$vs" ]]; then export vs2026_install="$vs" GYP_MSVS_OVERRIDE_PATH="$vs"; fi
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
    free_disk_windows
    use_roomiest_drive
  else
    # Spotlight would index the tens of GB the build writes.
    sudo mdutil -a -i off > /dev/null 2>&1 || true
    select_xcode
    free_disk_mac
  fi
  echo "Disk: $(disk)"
}

# Toolsets of the Windows image that Chromium does not need: tens of GB on C:.
# Best effort; a failure here only costs space.
free_disk_windows() {
  local tool
  df -h /c /d 2> /dev/null || true
  rm -rf /c/Android "/c/Program Files (x86)/Android" /c/ghcup /c/Strawberry /c/rtools* \
    "/c/Program Files/dotnet" "/c/Program Files/MongoDB" "/c/Program Files/PostgreSQL" \
    /c/msys64 /c/Miniconda /c/tools/php* 2> /dev/null || true
  for tool in "${RUNNER_TOOL_CACHE:-/c/hostedtoolcache/windows}"/*; do
    if [[ "$(basename "$tool")" != Python ]]; then rm -rf "$tool" 2> /dev/null || true; fi
  done
  df -h /c /d 2> /dev/null || true
}

# The checkout, temporary files and vpython's environments go on the drive
# with the most free space: C: alone ran out while Chromium's hooks unpacked
# their Python packages into C:\Windows\Temp.
use_roomiest_drive() {
  local drive=c
  if [[ -d /d ]] && (( $(df -k /d | awk 'NR == 2 { print $4 }') > $(df -k /c | awk 'NR == 2 { print $4 }') )); then drive=d; fi
  WORK="/$drive/cef"
  mkdir -p "/$drive/tmp" "/$drive/vpython"
  echo "Working on ${drive^^}: ($(df -h "/$drive" | awk 'NR == 2 { print $4 }') free)"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      echo "CEF_WORK=$WORK"
      echo "TEMP=${drive^^}:\\tmp"
      echo "TMP=${drive^^}:\\tmp"
      echo "VPYTHON_VIRTUALENV_ROOT=${drive^^}:\\vpython"
    } >> "$GITHUB_ENV"
  fi
}

# Chromium asks for one Windows SDK version (SDK_VERSION in
# build/vs_toolchain.py), with its "Debugging Tools for Windows". The image may
# have another one, so the one Chromium names is installed when it is missing.
# Installers by version, from https://learn.microsoft.com/windows/apps/windows-sdk/downloads
ensure_windows_sdk() {
  $IS_WINDOWS || return 0
  local kits="/c/Program Files (x86)/Windows Kits/10" version url
  version="$(sed -n "s/^SDK_VERSION = '\(.*\)'/\1/p" "$SRC/build/vs_toolchain.py" | tr -d '\r')"
  ls "$kits/Include" || true
  if [[ -d "$kits/Include/$version/um" && -f "$kits/Debuggers/x64/dbghelp.dll" ]]; then
    echo "Windows SDK $version and its Debugging Tools: present"
    return
  fi
  case "$version" in
    10.0.28000.0) url="https://go.microsoft.com/fwlink/?linkid=2382519" ;; # 10.0.28000.2957
    10.0.26100.0) url="https://go.microsoft.com/fwlink/?linkid=2382321" ;; # 10.0.26100.9457
    *) fail "Chromium wants Windows SDK $version; add its installer to ensure_windows_sdk." ;;
  esac
  echo "Installing Windows SDK $version from $url"
  curl -fsSL -o "$RUNNER_TEMP/winsdksetup.exe" "$url"
  # Every feature: the C++ headers and libraries, the tools and the debuggers.
  "$RUNNER_TEMP/winsdksetup.exe" //features + //quiet //norestart //ceip off
  ls "$kits/Include"
  [[ -d "$kits/Include/$version/um" ]] || fail "Windows SDK $version did not install."
  [[ -f "$kits/Debuggers/x64/dbghelp.dll" ]] || fail "The Debugging Tools for Windows did not install."
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

  ensure_windows_sdk

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
  # make_distrib.py also packs bootstrap.exe and bootstrapc.exe on Windows,
  # which cefclient does not need; automate-git.py adds them the same way.
  local targets=(cefclient)
  if [[ $PLATFORM == windows64 ]]; then targets+=(bootstrap bootstrapc); fi
  NINJA_STATUS="[%p %f/%t %e] " "$NINJA" -C "$OUT" -j "$(cpus)" "${targets[@]}" &
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
  local part rc=0 errors
  errors=$(mktemp)
  (cd "$STATE_DIR" && sha256 -c SHA256SUMS)
  mkdir -p "$(dirname "$WORK")"
  for part in "$STATE_DIR"/cef.tar.zst.part-*; do
    cat "$part"
    rm "$part"
  done | zstd -d -q --long=27 | tar_cmd -C "$(dirname "$WORK")" -xf - 2> "$errors" || rc=$?
  cat "$errors" >&2
  if (( rc != 0 )); then relink "$errors" || fail "tar failed (exit $rc)."; fi
  [[ -d "$OUT" ]] || fail "The unpacked tree has no $OUT."
  ensure_windows_sdk
  echo "Disk: $(disk)"
}

# Git Bash's tar makes a symlink by copying its target (MSYS emulates links),
# so a link whose target comes later in the archive fails and tar exits 2
# after unpacking everything else. Makes those links again now that the whole
# tree is there. Fails when tar reported anything else.
relink() {
  local line link target pattern="^tar: (.+): Cannot create symlink to '(.+)': No such file or directory$"
  if grep -Ev "Cannot create symlink to|Exiting with failure status" "$1" | grep -q .; then return 1; fi
  while IFS= read -r line; do
    [[ $line =~ $pattern ]] || continue
    link="$(dirname "$WORK")/${BASH_REMATCH[1]}"
    target=${BASH_REMATCH[2]}
    rm -rf "$link"
    (
      cd "$(dirname "$link")"
      if MSYS=winsymlinks:nativestrict ln -s "$target" "$(basename "$link")" 2> /dev/null; then exit 0; fi
      if [[ -e $target ]]; then cp -r "$target" "$(basename "$link")"; exit 0; fi
      echo "Skipped ${BASH_REMATCH[1]}: its target $target is not in the tree either."
    )
  done < "$1"
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

Built by $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/${SOURCE_RUN_ID:-$GITHUB_RUN_ID}"
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
  gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/${SOURCE_RUN_ID:-$GITHUB_RUN_ID}/artifacts" \
    --jq ".artifacts[] | select(.name | startswith(\"$prefix\")) | .id" |
    while read -r id; do
      gh api -X DELETE "repos/$GITHUB_REPOSITORY/actions/artifacts/$id"
      echo "Deleted artifact $id"
    done
}

# Runs one stage with its output also in a log. When the stage fails, the end
# of that log goes into an error annotation: annotations can be read without
# signing in to GitHub, the job logs cannot.
run_stage() {
  local log="${RUNNER_TEMP:-/tmp}/cef-stage.log" rc
  : > "$log"
  # Not "( ... ) || rc=$?": in that position bash ignores set -e inside the
  # subshell, and a failed command would not stop the stage.
  set +e
  ( set -e; "$@" ) > >(tee -a "$log") 2>&1
  rc=$?
  set -e
  sleep 1 # lets tee write the last lines
  if (( rc != 0 )); then annotate_failure "$1" "$rc" "$log"; fi
  return "$rc"
}

# An annotation shows only about 4 KB, and a step keeps at most 10 of them:
# first the lines that look like errors, then the end of the log in pieces.
annotate_failure() {
  local stage="$1" rc="$2" log="$3" chunks="${RUNNER_TEMP:-/tmp}/cef-annotations" file
  rm -rf "$chunks"
  mkdir -p "$chunks"
  grep -aiE 'error|fatal|failed|traceback|exception|denied|not found|no such|timed out|cannot|could not' "$log" |
    grep -avE '^\s*$' | tail -n 40 | cut -c1-300 > "$chunks/0-errors" || true
  tail -n 120 "$log" | cut -c1-300 | split -b 3500 - "$chunks/1-tail-"
  for file in $(ls "$chunks" | tail -n 9); do
    [[ -s "$chunks/$file" ]] || continue
    echo "::error title=cef-build.sh $stage failed (exit $rc), $file::$(sed -e 's/%/%25/g' -e 's/\r//g' "$chunks/$file" | awk '{ printf "%s%%0A", $0 }')"
  done
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    { echo "### cef-build.sh $stage failed (exit $rc)"; echo '```'; tail -n 200 "$log"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
  fi
}

case "${1:-}" in
  prepare) run_stage prepare ;;
  fetch) run_stage fetch ;;
  restore) run_stage restore ;;
  build) run_stage build ;;
  distrib) run_stage distrib ;;
  save) run_stage save ;;
  publish) run_stage publish ;;
  drop-artifacts) drop_artifacts "${2:-}" ;;
  *)
    echo "usage: $0 prepare|fetch|restore|build|distrib|save|publish|drop-artifacts <prefix>" >&2
    exit 2
    ;;
esac
