# Auto-deploy

The server rebuilds the site hourly and rsyncs it into the nginx webroot. No CI,
no webhooks, no secrets — and, since this revision, **no code from the repo runs
on the host**.

## Threat model, in short

Anyone who can get a commit onto `main` controls what the build does: `package.json`
lifecycle scripts, `build.js`, the sync scripts, and everything they download. In the
old setup those ran directly on the server (as a low-privilege user, but with network,
a home directory, and write access to the webroot). With `tutorials.data.yaml` now
mergeable without review, that had to change.

Now:

| Where           | What runs                                                          | Trust                                                  |
| --------------- | ------------------------------------------------------------------ | ------------------------------------------------------ |
| host            | `/usr/local/sbin/umstutorial-deploy.sh` + the systemd units       | installed by root, by hand, from a reviewed checkout    |
| container       | `git clone` → `npm ci` → `npm run sync` → `npm run build`          | untrusted; throw-away `node:22-bookworm`, non-root user |
| host            | sanity check + `rsync --delete` into the webroot                  | trusted script again                                    |

The container gets `--read-only`, `--cap-drop ALL`, `no-new-privileges`, memory / CPU /
pid limits, a wall-clock timeout, and exactly two writable host paths: a fresh staging
dir it puts the finished site in, and a scratch dir for the clone and npm cache. Both are
deleted after every run. It needs outbound network (GitHub, Google Docs), so that stays
on. The worst a malicious commit can do is publish a bad site or waste some CPU for
fifteen minutes.

Consequence for maintainers: **changes under `deploy/` are not picked up by the timer.**
The files in this directory are the source of truth, but they only take effect when
root re-runs `install.sh`. That is deliberate — the alternative is exactly the hole this
closes.

## What runs

| File                         | Purpose                                                                                   |
| ---------------------------- | ----------------------------------------------------------------------------------------- |
| `umstutorial-deploy.sh`      | Host runner. Starts the container, checks the result, rsyncs to the webroot. Idempotent; single-flight via `flock`. |
| `umstutorial-deploy.service` | Oneshot unit that runs the installed copy as root, with the site's `REPO_URL`/`BRANCH`/`WEBROOT`. |
| `umstutorial-deploy.timer`   | `OnCalendar=hourly`, `Persistent=true` so a missed run catches up after reboot.           |
| `install.sh`                 | Copies the three files above into place, pulls the image, enables the timer, runs once.   |

Defaults (override via `Environment=` lines in the installed unit):

- Repo: `https://github.com/uppsala-makerspace/umstutorial.git`, branch `main`
- Webroot: `/var/www/tutorial.uppsalamakerspace.se` (owner preserved; files `0644`, dirs `0755`)
- State: `/var/lib/umstutorial` (staging/scratch dirs during a run, `last-deployed-sha` after)
- Image: `node:22-bookworm`; limits 2 GB RAM, 2 CPUs, 512 pids, 15 min

## One-time setup on a server

Prerequisites: `docker` (daemon running), `rsync`, `systemd`, `git` (for the checkout
below only). No node on the host.

```sh
# 1. Get the deploy files. Any checkout works; this one can be deleted afterwards.
git clone --depth 1 https://github.com/uppsala-makerspace/umstutorial.git /root/umstutorial-src

# 2. Install. Copies the runner + units, pulls the image, enables the timer and
#    runs a first deploy synchronously so problems surface here.
sudo /root/umstutorial-src/deploy/install.sh
```

Point the nginx vhost at the webroot if it isn't already. Nothing under
`/root/umstutorial-src` is referenced after this.

## Migrating from the old setup (deploy user + checkout in /srv)

```sh
sudo systemctl disable --now umstutorial-deploy.timer
sudo /root/umstutorial-src/deploy/install.sh      # overwrites the units, re-enables the timer
sudo rm -rf /srv/umstutorial                       # old checkout; nothing uses it now
sudo userdel -r deploy                             # optional — the deploy user is no longer needed
```

The webroot is left alone; the first run of the new runner rsyncs over it.

## Updating the deploy files

```sh
git -C /root/umstutorial-src pull      # or a fresh clone
sudo /root/umstutorial-src/deploy/install.sh
```

Site content and code changes need none of this — the hourly timer builds whatever
is on `main`. Only `deploy/*` needs the manual step. Every few months, also
`docker pull node:22-bookworm` to pick up base-image fixes (the runner only pulls when
the image is missing).

## Operator commands

```sh
systemctl status umstutorial-deploy.timer         # next run + last result
journalctl -u umstutorial-deploy.service -n 50    # recent deploy log
journalctl -fu umstutorial-deploy.service         # follow live
sudo systemctl start umstutorial-deploy.service   # force a deploy now
cat /var/lib/umstutorial/last-deployed-sha        # what's live
```

A run ends with `= deployed umstutorial=<sha>`. Everything the container prints
(clone, npm, sync, build) goes to the journal too. If the build fails, the webroot is
not touched.

## Trying the runner locally

The runner is plain bash and only needs docker; you can dry-run it against a scratch
webroot without root (the container user then has to be your own uid):

```sh
mkdir -p /tmp/dt/state /tmp/dt/webroot
STATE_DIR=/tmp/dt/state LOCK=/tmp/dt/lock WEBROOT=/tmp/dt/webroot BUILD_UID=$(id -u) \
  deploy/umstutorial-deploy.sh
```

## Removing

```sh
sudo systemctl disable --now umstutorial-deploy.timer
sudo rm /etc/systemd/system/umstutorial-deploy.{service,timer} /usr/local/sbin/umstutorial-deploy.sh
sudo systemctl daemon-reload
sudo rm -rf /var/lib/umstutorial
```

The webroot stays; remove it by hand if you also want that gone.

## Adapting for other repos

Copy `deploy/` to a sibling repo and change:

1. `REPO_URL` / `WEBROOT` defaults in `umstutorial-deploy.sh` and the `Environment=`
   lines in the service.
2. The `BUILD_SCRIPT` heredoc in the runner if that repo's build steps differ
   (it assumes `npm ci && npm run sync && npm run build` producing `dist/`).
3. The unit/runner names (`umstutorial-deploy` throughout).
