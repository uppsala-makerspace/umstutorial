#!/usr/bin/env bash
# Sync umsme/tutorial into sources/umsme/ via shallow + sparse checkout.
# Idempotent: re-run to update; records the synced SHA in sources/umsme/.synced-sha.

set -euo pipefail

REPO_SSH="git@github.com:uppsala-makerspace/umsme.git"
REPO_HTTPS="https://github.com/uppsala-makerspace/umsme.git"
REF="master"
PROTO="ssh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)   REF="$2"; shift 2 ;;
    --ssh)   PROTO="ssh"; shift ;;
    --https) PROTO="https"; shift ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--ref <ref>] [--ssh|--https]

  --ref <ref>   branch, tag, or SHA to sync (default: master)
  --ssh         use SSH clone URL (default)
  --https       use HTTPS clone URL
EOF
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_URL="$REPO_SSH"
[[ "$PROTO" == "https" ]] && REPO_URL="$REPO_HTTPS"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
dest="$root/sources/umsme"

mkdir -p "$root/sources"

if [[ ! -d "$dest/.git" ]]; then
  echo "→ cloning $REPO_URL into $dest (shallow, sparse: tutorial/)"
  git clone --filter=blob:none --no-checkout --depth=1 "$REPO_URL" "$dest"
  git -C "$dest" sparse-checkout init --cone
  git -C "$dest" sparse-checkout set tutorial
fi

echo "→ fetching $REF"
git -C "$dest" fetch --depth=1 origin "$REF"
git -C "$dest" checkout -q FETCH_HEAD

sha="$(git -C "$dest" rev-parse HEAD)"
echo "$sha" > "$dest/.synced-sha"

count="$(find "$dest/tutorial" -type f 2>/dev/null | wc -l | tr -d ' ')"
echo "✓ synced umsme @ $sha"
echo "  ref: $REF"
echo "  files under tutorial/: $count"
