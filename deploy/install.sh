#!/usr/bin/env bash
# Install (or update) the umstutorial deploy runner on a server.
#
# Run as root from inside a checkout of this repo — any checkout, e.g. a
# temporary clone under /root. Nothing is executed from the checkout
# afterwards: this copies the runner to /usr/local/sbin and the systemd units
# to /etc/systemd/system, and that is what runs from then on.
#
#   sudo ./deploy/install.sh
#
# Idempotent: re-run whenever deploy/umstutorial-deploy.sh or the units change
# in git. The hourly timer does NOT pick those changes up by itself — that is
# the point (see deploy/README.md).
#
# Env overrides: UNIT_DIR, BIN_DIR, IMAGE, RUN_NOW=0 to skip the first deploy.

set -euo pipefail

UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
BIN_DIR=${BIN_DIR:-/usr/local/sbin}
IMAGE=${IMAGE:-node:22-bookworm}
RUN_NOW=${RUN_NOW:-1}

step() { printf '\n→ %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
fail() { printf '\n✗ %s\n' "$*" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner_src="$here/umstutorial-deploy.sh"
service_src="$here/umstutorial-deploy.service"
timer_src="$here/umstutorial-deploy.timer"

[[ $EUID -eq 0 ]] || fail "run as root (or with sudo)"
for f in "$runner_src" "$service_src" "$timer_src"; do
  [[ -f "$f" ]] || fail "missing $f — run from a checkout of the repo"
done

step "checking prerequisites"
for c in docker rsync timeout flock mktemp systemctl install; do
  command -v "$c" >/dev/null || fail "missing required command: $c"
done
docker info >/dev/null 2>&1 || fail "docker daemon not reachable — is docker installed and running?"
ok "docker, rsync, systemd present"

step "installing runner to $BIN_DIR"
install -m 0755 -o root -g root "$runner_src" "$BIN_DIR/umstutorial-deploy.sh"
ok "$BIN_DIR/umstutorial-deploy.sh"

step "installing systemd units to $UNIT_DIR"
install -m 0644 -o root -g root "$service_src" "$UNIT_DIR/umstutorial-deploy.service"
install -m 0644 -o root -g root "$timer_src"   "$UNIT_DIR/umstutorial-deploy.timer"
ok "umstutorial-deploy.service, umstutorial-deploy.timer"

step "pulling build image $IMAGE"
docker pull --quiet "$IMAGE" >/dev/null
ok "image present"

step "systemctl daemon-reload + enable timer"
systemctl daemon-reload
systemctl enable --now umstutorial-deploy.timer
ok "timer enabled"
systemctl status --no-pager umstutorial-deploy.timer | head -8 || true

if [[ "$RUN_NOW" == "1" ]]; then
  step "running first deploy synchronously (a few minutes on a cold image)"
  if systemctl start umstutorial-deploy.service; then
    ok "first deploy completed"
  else
    journalctl -u umstutorial-deploy.service -n 80 --no-pager || true
    fail "first deploy failed — see the log above"
  fi
fi

cat <<EOF

install complete.

  status:  systemctl status umstutorial-deploy.timer
  logs:    journalctl -u umstutorial-deploy.service -n 50 --no-pager
  follow:  journalctl -fu umstutorial-deploy.service
  force:   systemctl start umstutorial-deploy.service
  update:  git pull in a checkout, then re-run this script
EOF
