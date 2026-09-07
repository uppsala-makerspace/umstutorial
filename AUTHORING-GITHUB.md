# Authoring tutorials in a GitHub repo

The **github** source pulls a tutorial from a directory inside a **public**
GitHub repo. Each tutorial is one directory containing a main markdown file
(default `README.md`) plus its image files as siblings. Tutorials can live in
different directories of the same repo, or in separate repos — each tutorial
names its own repo and directory.

## Repo layout

```
<repo>/
  <dir>/
    README.md          # the tutorial text (the "main file")
    step-1.png         # images, referenced from README.md
    overview.jpg
```

- The main file must be markdown. Its **first `# H1` is used as the tutorial
  title**, and the first regular paragraph after it becomes the summary shown in
  tag listings — so start the file with `# Title` followed by an intro sentence.
- Reference images with **relative links** to the files sitting next to the
  markdown, e.g. `![Overview](overview.jpg)` or `![Step 1](./img/step-1.png)`.
  The sync copies each referenced file into the site's shared screens folder as
  `<slug>__<filename>` and rewrites the link automatically — you don't write
  `../screens/` yourself.
- Remote images (`https://...`) and absolute paths (`/...`) are left as-is and
  **not** downloaded.
- Both markdown images `![alt](path)` and inline HTML `<img src="path">` are
  handled. Reference-style images (`![alt][ref]`) are not.

## Add it to the site

Add an entry to `tutorials` in [`tutorials.data.yaml`](tutorials.data.yaml):

```yaml
- {source: github, slug: <slug>, tag: <tag>,
   repo: https://github.com/<org>/<repo>,
   dir: <subdir>,                 # optional, default repo root
   ref: main,                     # optional, default the remote's HEAD
   files: {sv: README.md}}        # optional, default {sv: README.md}
```

A pull request that touches only `tutorials.data.yaml` needs no code review —
you can merge it yourself once the "Check build" status is green. Anything
else needs a reviewed pull request. The file is validated strictly (run
`node scripts/validate-data.js` locally to check), so keep to the shapes below.

- `slug` is the URL segment on the site (`/<tag>/<slug>/`): letters, digits and
  `-` only, unique across the file.
- `tag` must exist under `tags:` in the same file. To add a new tag, add it
  there with `en`/`sv` labels, e.g. `print3d: {en: 3D printing, sv: 3D-skrivare}`.
- `repo` must be an `https://github.com/<owner>/<repo>[.git]` URL. Other hosts,
  ssh URLs and anything starting with `-` are rejected.
- `dir` is only needed when the tutorial isn't at the repo root. Relative, no
  `..`.
- `ref` pins a branch, tag, or commit SHA. Omit it to track the default branch.
- `files` maps each language to its main file. Swedish-only is fine (the default
  is `{ sv: "README.md" }`). To add English later, point it at that language's
  file, e.g. `files: { sv: "README.md", en: "README.en.md" }`. Values are bare
  `*.md` filenames inside `dir` — no paths.

## Build and preview

```sh
npm run sync:github   # clones the repos and populates sources/github/
npm run build         # writes dist/
npm run serve         # http://localhost:8000
```

`sources/` is gitignored — upstream content never enters this repo's history.
Re-running `npm run sync:github` wipes and rebuilds `sources/github/` from
scratch, so removing a tutorial from `tutorials.data.yaml` drops it on the next sync.
