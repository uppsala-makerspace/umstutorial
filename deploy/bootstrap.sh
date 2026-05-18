#!/usr/bin/env bash
# One-time setup for the umstutorial auto-deploy on a fresh server.
# Run as root from inside the cloned repo:
#
#   sudo DEPLOY_USER=deploy ./deploy/bootstrap.sh
#
# Idempotent: re-run after editing the systemd units to reload them.

set -euo pipefail

DEPLOY_USER=${DEPLOY_USER:?set DEPLOY_USER to the user that owns /srv/umstutorial and the webroot}
CLONE=${CLONE:-/srv/umstutorial}
WEBROOT=${WEBROOT:-/var/www/tutorial.uppsalamakerspace.se}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
MIN_NODE_MAJOR=${MIN_NODE_MAJOR:-18}
SYSTEMD_PATH=${SYSTEMD_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}

step() { printf '\n→ %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
fail() { printf '\n✗ %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "run as root (or with sudo); needs to write to $UNIT_DIR"

step "config"
echo "  DEPLOY_USER  = $DEPLOY_USER"
echo "  CLONE        = $CLONE"
echo "  WEBROOT      = $WEBROOT"
echo "  UNIT_DIR     = $UNIT_DIR"
echo "  MIN_NODE     = $MIN_NODE_MAJOR"
echo "  SYSTEMD_PATH = $SYSTEMD_PATH"

step "checking required commands available to root"
for c in git node npm rsync systemctl install sed flock sudo getent; do
  command -v "$c" >/dev/null || fail "missing required command (as root): $c"
done
ok "all required commands present as root"

step "checking $CLONE is a git checkout"
[[ -d "$CLONE/.git" ]] || fail "no git checkout at $CLONE; clone the repo there first"
ok "git checkout found"

step "checking deploy user '$DEPLOY_USER' exists"
id -u "$DEPLOY_USER" >/dev/null 2>&1 \
  || fail "user '$DEPLOY_USER' does not exist (create it first, e.g.: useradd -r -m -d $CLONE -s /usr/sbin/nologin $DEPLOY_USER)"
deploy_home="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
ok "user exists (home: $deploy_home)"

step "probing node visible to deploy user"
# Two probes matter:
#   login   = interactive login shell — sources .bashrc / .profile, so nvm
#             initialization (if any) runs. This is what `sudo -iu` sees.
#   service = the bare env systemd will use: clean PATH, no shell init,
#             no nvm. This is what the systemd unit will see.
# If `service` finds no node, the timer will fail every run even if `login`
# looks fine. That's the most common nvm pitfall.
#
# Note: `command -v` is a shell builtin, so it must be invoked through a
# shell (env -i can't exec it directly). bash without --noprofile/--norc
# is fine here because `-c` is non-interactive and doesn't source init
# files unless BASH_ENV is set — which it isn't, because env -i cleared
# the environment.
login_node="$(sudo -u "$DEPLOY_USER" -i bash -lc 'command -v node 2>/dev/null' 2>/dev/null || true)"
login_ver="$(sudo -u "$DEPLOY_USER" -i bash -lc 'node --version 2>/dev/null' 2>/dev/null || true)"
svc_node="$(sudo -u "$DEPLOY_USER" env -i HOME="$deploy_home" PATH="$SYSTEMD_PATH" bash -c 'command -v node 2>/dev/null' 2>/dev/null || true)"
svc_ver="$( sudo -u "$DEPLOY_USER" env -i HOME="$deploy_home" PATH="$SYSTEMD_PATH" bash -c 'node --version  2>/dev/null' 2>/dev/null || true)"

printf '  login shell   : %s %s\n' "${login_node:-<not found>}" "${login_ver}"
printf '  service env   : %s %s\n' "${svc_node:-<not found>}"   "${svc_ver}"
printf '  service PATH  : %s\n' "$SYSTEMD_PATH"

if [[ -z "$svc_node" ]]; then
  cat >&2 <<EOF

✗ deploy user '$DEPLOY_USER' has no node on the systemd PATH.
  The systemd service runs without shell init (no nvm sourcing).
  Even if 'login shell' above shows a node version, the service will fail.

  Fix one of:
    1. Install node ≥ $MIN_NODE_MAJOR system-wide so it lives in /usr/bin or
       /usr/local/bin (NodeSource, your distro package, or fnm system-wide).
       This is the recommended path — it removes nvm from the deploy path.
    2. Install nvm under '$DEPLOY_USER' and add an Environment=PATH=… line
       to /etc/systemd/system/umstutorial-deploy.service pointing to the
       nvm node bin directory, then 'systemctl daemon-reload' and re-run
       this script.

  See deploy/README.md → "Node and the deploy user" for the exact commands.
EOF
  exit 1
fi

# Parse "v22.21.0" → "22"
ver_clean="${svc_ver#v}"
svc_major="${ver_clean%%.*}"
if [[ -z "$svc_major" ]] || ! [[ "$svc_major" =~ ^[0-9]+$ ]] || (( svc_major < MIN_NODE_MAJOR )); then
  fail "deploy user's node ($svc_ver) is older than required (≥ $MIN_NODE_MAJOR). See deploy/README.md."
fi
ok "deploy user has node $svc_ver at $svc_node"

step "ensuring webroot $WEBROOT exists"
mkdir -p "$WEBROOT"
ok "webroot ready"

step "chowning $CLONE and $WEBROOT to $DEPLOY_USER"
chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$CLONE" "$WEBROOT"
ok "ownership set"

step "installing node deps as $DEPLOY_USER (npm ci)"
# Use a login shell so nvm has a chance to initialise; npm ci output is
# left un-silenced so failures here are visible immediately.
sudo -u "$DEPLOY_USER" -i bash -lc "cd '$CLONE' && npm ci"
ok "deps installed"

step "installing systemd units to $UNIT_DIR"
service_src="$CLONE/deploy/umstutorial-deploy.service"
timer_src="$CLONE/deploy/umstutorial-deploy.timer"
service_dst="$UNIT_DIR/umstutorial-deploy.service"
timer_dst="$UNIT_DIR/umstutorial-deploy.timer"

sed "s/__DEPLOY_USER__/$DEPLOY_USER/g" "$service_src" > "$service_dst"
chmod 0644 "$service_dst"
install -m 0644 "$timer_src" "$timer_dst"
ok "installed $service_dst"
ok "installed $timer_dst"

step "systemctl daemon-reload"
systemctl daemon-reload
ok "daemon reloaded"

step "enabling and starting umstutorial-deploy.timer"
systemctl enable --now umstutorial-deploy.timer
ok "timer enabled and started"
systemctl status --no-pager umstutorial-deploy.timer | head -10 || true

step "running first deploy synchronously (this can take ~30s on first run)"
if systemctl start umstutorial-deploy.service; then
  ok "first deploy completed"
  systemctl status --no-pager umstutorial-deploy.service | head -10 || true
else
  warn "deploy.service failed; recent logs follow"
  journalctl -u umstutorial-deploy.service -n 100 --no-pager || true
  fail "first deploy failed — investigate the logs above"
fi

cat <<EOF

bootstrap complete.

  status:  systemctl status umstutorial-deploy.timer
  logs:    journalctl -u umstutorial-deploy.service -n 50 --no-pager
  follow:  journalctl -fu umstutorial-deploy.service
  force:   systemctl start umstutorial-deploy.service
EOF
