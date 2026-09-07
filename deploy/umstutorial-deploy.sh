#!/usr/bin/env bash
# Host-side deploy runner for umstutorial.
#
# Installed by root to /usr/local/sbin/umstutorial-deploy.sh and run hourly by
# the systemd timer. This file is the ONLY code on the host that the deploy
# trusts. Everything from the repository — package.json lifecycle scripts,
# build.js, the sync scripts, the tutorial sources — runs inside a throw-away
# Docker container that can write to exactly two host directories: the staging
# dir it hands back the site in, and a scratch dir for the clone and npm cache.
# When the container exits, this script sanity-checks
# the result and rsyncs it into the webroot.
#
# The copy in the git repo (deploy/umstutorial-deploy.sh) is the source of
# truth for maintenance, but it is NOT executed from the checkout and NOT
# picked up automatically. Re-run deploy/install.sh as root to roll out a
# change to this file. See deploy/README.md for the threat model.
#
# Configured via env (defaults below); the systemd unit sets the site values.

set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/uppsala-makerspace/umstutorial.git}
BRANCH=${BRANCH:-main}
WEBROOT=${WEBROOT:-/var/www/tutorial.uppsalamakerspace.se}
STATE_DIR=${STATE_DIR:-/var/lib/umstutorial}
LOCK=${LOCK:-/run/lock/umstutorial-deploy.lock}

IMAGE=${IMAGE:-node:22-bookworm}
BUILD_TIMEOUT=${BUILD_TIMEOUT:-15m}
BUILD_UID=${BUILD_UID:-1000}       # the `node` user in the official image
BUILD_MEMORY=${BUILD_MEMORY:-2g}
BUILD_CPUS=${BUILD_CPUS:-2}
BUILD_PIDS=${BUILD_PIDS:-512}
# Owner for files in the webroot. Default: whoever owns the webroot today, or
# root:root if it doesn't exist yet.
WEBROOT_OWNER=${WEBROOT_OWNER:-}

step() { printf '\n→ %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
fail() { printf '\n✗ %s\n' "$*" >&2; exit 1; }

step "deploy starting"
echo "  REPO_URL = $REPO_URL @ $BRANCH"
echo "  WEBROOT  = $WEBROOT"
echo "  IMAGE    = $IMAGE"
echo "  user     = $(id -un) ($(id -u))"

for c in docker rsync timeout flock mktemp; do
  command -v "$c" >/dev/null || fail "missing required command: $c"
done
docker info >/dev/null 2>&1 || fail "cannot talk to the docker daemon"

# Single-flight: if another run is in progress, exit 0 quietly so the timer
# doesn't pile up failures.
mkdir -p "$(dirname "$LOCK")" "$STATE_DIR"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "  another deploy is running; skipping"
  exit 0
fi

# Two host dirs the container may write, both created empty every run and
# removed on exit, success or not:
#   STAGE   /out   — the finished site, picked up by rsync below
#   SCRATCH /work  — clone, node_modules, npm cache, TMPDIR. On disk rather
#                    than tmpfs so a build with many source repos doesn't eat
#                    RAM (tmpfs pages count against the container's memory).
STAGE=$(mktemp -d "$STATE_DIR/stage.XXXXXX")
SCRATCH=$(mktemp -d "$STATE_DIR/scratch.XXXXXX")
cleanup() { rm -rf "$STAGE" "$SCRATCH"; }
trap cleanup EXIT
chown "$BUILD_UID:$BUILD_UID" "$STAGE" "$SCRATCH"
chmod 0700 "$STAGE" "$SCRATCH"
mkdir -p "$SCRATCH/tmp" && chown "$BUILD_UID:$BUILD_UID" "$SCRATCH/tmp"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  step "pulling $IMAGE"
  docker pull --quiet "$IMAGE"
fi

# What runs inside the container. Deliberately inline here rather than in the
# repo: the repo is untrusted input, this script is not. Shallow clone of the
# requested branch, install deps (lifecycle scripts included — that is exactly
# what we are sandboxing), sync sources, build, hand back dist/ plus the SHA.
read -r -d '' BUILD_SCRIPT <<'EOF' || true
set -euo pipefail
echo "node $(node --version), npm $(npm --version), git $(git --version | cut -d' ' -f3)"
git clone --quiet --depth 1 --branch "$BRANCH" -- "$REPO_URL" src
cd src
sha=$(git rev-parse HEAD)
echo "umstutorial at $sha"
npm ci --no-audit --no-fund
npm run sync
npm run build
cp -a dist/. /out/
echo "$sha" > /out/.deployed-sha
EOF

step "building in container (timeout $BUILD_TIMEOUT)"
# --read-only: the image filesystem is immutable; the only writable paths are
# the two bind mounts and a small tmpfs /tmp as a safety net. TMPDIR points
# into the scratch mount so git, npm and the sync scripts (mkdtemp) all land
# there. exec is needed because npm runs binaries from node_modules/.bin.
timeout --kill-after=30s "$BUILD_TIMEOUT" \
  docker run --rm --init \
    --name umstutorial-build \
    --user "$BUILD_UID:$BUILD_UID" \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --read-only \
    --tmpfs /tmp:rw,nosuid,size=64m,uid="$BUILD_UID",gid="$BUILD_UID" \
    --memory "$BUILD_MEMORY" --cpus "$BUILD_CPUS" --pids-limit "$BUILD_PIDS" \
    --network bridge \
    --mount "type=bind,src=$SCRATCH,dst=/work" \
    --mount "type=bind,src=$STAGE,dst=/out" \
    -e HOME=/work -e TMPDIR=/work/tmp -e npm_config_cache=/work/.npm \
    -e REPO_URL="$REPO_URL" -e BRANCH="$BRANCH" \
    -w /work \
    "$IMAGE" bash -c "$BUILD_SCRIPT" \
  || fail "container build failed (exit $?)"
ok "container finished"

step "checking build output"
[[ -f "$STAGE/index.html" ]] || fail "no index.html in build output — refusing to publish"
[[ -s "$STAGE/.deployed-sha" ]] || fail "no .deployed-sha in build output"
sha=$(tr -cd '0-9a-f' < "$STAGE/.deployed-sha")
[[ ${#sha} -eq 40 ]] || fail "malformed .deployed-sha"
mv "$STAGE/.deployed-sha" "$STATE_DIR/last-deployed-sha"   # keep it out of the webroot
ok "output looks sane ($(find "$STAGE" -type f | wc -l) files)"

step "publishing to $WEBROOT"
if [[ -z "$WEBROOT_OWNER" ]]; then
  if [[ -d "$WEBROOT" ]]; then
    WEBROOT_OWNER=$(stat -c '%u:%g' "$WEBROOT")
  else
    WEBROOT_OWNER=root:root
  fi
fi
mkdir -p "$WEBROOT"
# --chown/--chmod: files come out of the container owned by BUILD_UID; the
# webroot gets its own owner and plain world-readable modes regardless.
rsync -a --delete \
  --chown="$WEBROOT_OWNER" --chmod=D0755,F0644 \
  "$STAGE"/ "$WEBROOT"/
ok "published"

printf '\n= deployed umstutorial=%s\n' "$sha"
