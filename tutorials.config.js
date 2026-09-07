// Declares where tutorial content comes from, how it's grouped, and which
// language sits at the site root (others get a `/<lang>/` prefix).
//
// The tag labels and the tutorial list are DATA and live in
// tutorials.data.yaml, so they can be edited (and their changes merged)
// without a code review. This file holds the code-adjacent bits — DEFAULT_LANG
// and SOURCES — which stay review-gated.
//
// SOURCES: keyed by source name. `root` is where the source's tutorial tree
// lives relative to the repo root; `screensDirs` are layered into
// dist/screens/<source>/ in order (later overlays earlier); `forceManual`
// names files that must come from the manual dir even when generated.
//
// TAGS / TUTORIALS: loaded from tutorials.data.yaml (tutorials there are a
// tag → slug → entry hierarchy; see that file for the per-source entry
// shapes) and run through scripts/data-schema.js before
// anything else sees them. Because the data file bypasses code review, every
// field that ends up in a git command, URL, or filesystem path is whitelisted
// there; a file that fails validation aborts the build and every sync script.
// Re-exported here so build.js and the sync scripts keep importing them from
// this module unchanged.

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { load } from "js-yaml";
import { validateData, flattenTutorials } from "./scripts/data-schema.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

export const DEFAULT_LANG = "sv";

export const SOURCES = {
  umsme: {
    root: "sources/umsme/tutorial",
    screensDirs: ["screens-manual", "screens-generated"],
    forceManual: ["doors-en.png", "doors-sv.png"],
    requireSyncedSha: true,
  },
  local: {
    root: "content",
    screensDirs: ["screens"],
  },
  gdrive: {
    root: "sources/gdrive/tutorial",
    screensDirs: ["screens"],
    requireSyncedSha: true,
  },
  github: {
    root: "sources/github/tutorial",
    screensDirs: ["screens"],
    requireSyncedSha: true,
  },
};

// TUTORIALS_DATA=<path> points at an alternate data file (used to exercise
// the validator against deliberately broken input).
export const DATA_PATH = process.env.TUTORIALS_DATA
  ? resolve(process.env.TUTORIALS_DATA)
  : resolve(__dirname, "tutorials.data.yaml");

const data = validateData(
  load(readFileSync(DATA_PATH, "utf8")),
  Object.keys(SOURCES),
);

export const TAGS = data.tags;
// The YAML groups tutorials by tag and slug; the rest of the code wants the
// flat ordered list. Order within a tag is the YAML key order.
export const TUTORIALS = flattenTutorials(data.tutorials);
