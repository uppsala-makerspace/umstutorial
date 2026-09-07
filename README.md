# umstutorial

Tutorials webb that aggregates content from multiple sources into a single bilingual (EN/SV) site with tag-based navigation.

## Sources

- **umsme** — markdown and auto-generated screens pulled from the [`umsme`](https://github.com/uppsala-makerspace/umsme) app repo's `tutorial/` directory. Screens are produced by the app's Storybook (`tutorial/screenshot.js` inside umsme) and must stay there.
- **local** — tutorials authored directly in this repo under `content/`.
- **gdrive** — tutorials authored in publicly-shared Google Docs. The sync downloads each doc's markdown export, decodes its inline base64 images into `sources/gdrive/tutorial/screens/`, flattens layout-grid tables, and strips trailing version-history sections. See [`AUTHORING-GDRIVE.md`](AUTHORING-GDRIVE.md) for the author-facing format spec.
- **github** — tutorials authored as a directory inside a public GitHub repo, each with a main markdown file (default `README.md`) plus sibling image files. The sync clones the repo, copies the referenced images into `sources/github/tutorial/screens/`, and rewrites their links. Each tutorial names its own `repo`/`dir`/`ref`/`files`, so tutorials can live in different directories of one repo or across several repos. See [`AUTHORING-GITHUB.md`](AUTHORING-GITHUB.md) for the author-facing format spec.

## First-time setup

```sh
npm install
npm run sync     # populates gitignored sources/ (umsme shallow-clone + gdrive markdown export)
npm run build    # writes dist/
npm run serve    # serves dist/ at http://localhost:8000
```

Or run all three in order:

```sh
npm run dev
```

## Syncing

`npm run sync` runs both source-specific syncs in order. You can also run them individually:

- `npm run sync:umsme` — shallow + sparse checkout of the umsme repo into `sources/umsme/`, limited to the `tutorial/` directory. The synced commit SHA is recorded in `sources/umsme/.synced-sha`.
  - Re-running updates to the latest `master`.
  - `scripts/sync-umsme.sh --ref <branch|tag|sha>` syncs a specific ref instead.
- `npm run sync:gdrive` — fetches each `{ source: "gdrive" }` tutorial in `tutorials.data.yaml` from Google Docs' markdown export, decodes inline base64 images, cleans the markdown (heading quirks, table flattening, trailing version-history removal), and writes to `sources/gdrive/tutorial/`. Per-doc sha256 hashes are recorded in `sources/gdrive/.synced-sha`. Each gdrive tutorial entry carries a `docs: { en?, sv? }` map of Google Doc IDs — single-language tutorials are allowed.
- `npm run sync:github` — clones each repo referenced by a `{ source: "github" }` tutorial in `tutorials.data.yaml`, reads the main markdown file, copies its sibling images into `sources/github/tutorial/screens/` (named `<slug>__<file>`), rewrites the image links to `../screens/...`, and writes to `sources/github/tutorial/`. The checked-out commit SHA per `<repo>@<ref>` is recorded in `sources/github/.synced-sha`. Each github entry carries `repo`, optional `dir`/`ref`, and an optional `files: { en?, sv? }` map of main-file names per language — single-language tutorials are allowed. See [`AUTHORING-GITHUB.md`](AUTHORING-GITHUB.md).

`sources/` is gitignored — upstream content never enters this repo's history.

## URLs

Swedish is the default language and lives at the site root: `/`, `/app/`, `/app/installApp/`. English is mirrored one level deeper under `/en/`: `/en/`, `/en/app/`, `/en/app/installApp/`. The language switcher on every page links to the paired URL in the other language, so each tutorial is deep-linkable in either language.

The default language is set by `DEFAULT_LANG` in `tutorials.config.js`.

## Authoring tutorials locally

1. Create `content/en/<slug>.md` and `content/sv/<slug>.md`.
2. Reference screens (if any) as `../screens/<name>.png`, with the actual file at `content/screens/<name>.png`.
3. Add an entry to `tutorials` in `tutorials.data.yaml`:
   ```yaml
   - {source: local, slug: <slug>, tag: <tag>}
   ```
4. `npm run build`.

## Content data: `tutorials.data.yaml`

`tutorials.data.yaml` holds the tag labels and the tutorial list as plain data
(no code). `DEFAULT_LANG` and `SOURCES` stay in `tutorials.config.js`, which
reads and validates the YAML.

A pull request that touches **only** `tutorials.data.yaml` needs no code
review: the file is deliberately left unowned in `.github/CODEOWNERS`, so with
the branch protection below the PR's author can merge it as soon as the
"Check build" status is green. A PR touching anything else needs the
maintainer's approval. No bot account or token is involved.

This is safe because the file is validated strictly before anything uses it
(`scripts/data-schema.js`, run by `tutorials.config.js` and as the first CI
step via `node scripts/validate-data.js`): `slug` is `[A-Za-z0-9-]` and unique,
`tag` must exist, `repo` must be an `https://github.com/<owner>/<repo>` URL,
`dir`/`files` can't escape the repo, `docs` are Google Doc ids, and unknown
fields are rejected. On top of that, the production build runs in a throw-away
container (see Deployment), so even a schema gap can't reach the server.

Branch protection for `main` (repository settings, one-time):

- Require a pull request before merging, **required approvals: 0**
- **Require review from Code Owners** — on
- Require status checks to pass: `check_build` (and `deploy_scripts`)
- Settings → General → **Allow auto-merge** — on, so authors can queue a
  data-only PR to merge when CI finishes

## Layout

```
build.js              # build pipeline
template.html         # page shell
site.css              # styles
tutorials.data.yaml   # TAGS + TUTORIALS (content data; mergeable without review)
tutorials.config.js   # DEFAULT_LANG, SOURCES; loads + validates tutorials.data.yaml
scripts/data-schema.js   # strict schema for tutorials.data.yaml
scripts/validate-data.js # CLI wrapper for the schema check (CI runs it)
scripts/sync-umsme.sh # umsme source loader
scripts/sync-gdrive.js # gdrive source loader
scripts/sync-github.js # github source loader
content/              # locally-authored tutorials
deploy/               # server-side auto-deploy (systemd timer + docker); installed by hand
sources/              # gitignored — populated by sync scripts
dist/                 # gitignored — build output
```

## Deployment

The production site at `tutorial.uppsalamakerspace.se` rebuilds hourly via a
server-side systemd timer. The timer runs a small host script that clones
`main`, builds it inside a locked-down, throw-away Docker container, and rsyncs
the result into the webroot — nothing from this repo executes on the host
itself. The host script lives in `deploy/` but is installed by root by hand and
is **not** updated automatically. See [`deploy/README.md`](deploy/README.md)
for the threat model, setup, migration and operator commands.
