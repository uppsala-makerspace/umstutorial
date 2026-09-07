// Strict schema check for tutorials.data.yaml.
//
// tutorials.data.yaml is the one file that can be merged without a code
// review, so everything in it must be inert data. Anything that reaches a
// shell, git, a URL, or a filesystem path is whitelisted here to a shape that
// cannot carry options, alternate protocols, or path traversal:
//
//   repo   https://github.com/<owner>/<repo>[.git]  — no ext::, ssh, file:,
//          or "-"-prefixed values that git would read as flags
//   ref    plain branch/tag/SHA characters, no leading "-"
//   dir    relative, no ".." segments
//   files  bare *.md filenames
//   slug   [A-Za-z0-9-]  — used verbatim in filenames and URLs
//   docs   Google Doc ids
//
// Unknown fields are rejected so a new field can't silently become an
// attack surface before its consumer validates it.
//
// Imported by tutorials.config.js, so build.js and every sync script only ever
// see validated data. scripts/validate-data.js is the CLI wrapper CI runs.
// (Kept free of imports from tutorials.config.js: that module imports this
// one, and a cycle plus top-level await would deadlock.)

const LANGS = ["en", "sv"];

const RE = {
  tagKey: /^[A-Za-z0-9][A-Za-z0-9_-]*$/,
  slug: /^[A-Za-z0-9][A-Za-z0-9-]*$/,
  repo: /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(\.git)?$/,
  ref: /^[A-Za-z0-9._][A-Za-z0-9._/-]*$/,
  dirSegment: /^[A-Za-z0-9._-]+$/,
  file: /^[A-Za-z0-9._-]+\.md$/,
  docId: /^[A-Za-z0-9_-]{20,}$/,
};

const FIELDS = {
  umsme: [],
  local: [],
  gdrive: ["docs"],
  github: ["repo", "dir", "ref", "files"],
};

export class DataError extends Error {}

const fail = (where, msg) => {
  throw new DataError(`tutorials.data.yaml: ${where}: ${msg}`);
};

const isPlainObject = (v) =>
  v !== null && typeof v === "object" && !Array.isArray(v);

const isNonEmptyString = (v) => typeof v === "string" && v.length > 0;

function checkKeys(where, obj, allowed) {
  for (const k of Object.keys(obj)) {
    if (!allowed.includes(k)) {
      fail(where, `unknown field "${k}" (allowed: ${allowed.join(", ")})`);
    }
  }
}

function checkLangMap(where, map, valueRe, valueDesc) {
  if (!isPlainObject(map)) fail(where, "must be a map of language → value");
  checkKeys(where, map, LANGS);
  if (Object.keys(map).length === 0) fail(where, "must have at least one language");
  for (const [lang, v] of Object.entries(map)) {
    if (!isNonEmptyString(v) || !valueRe.test(v)) {
      fail(`${where}.${lang}`, `must be ${valueDesc}, got ${JSON.stringify(v)}`);
    }
  }
}

function checkTags(tags) {
  if (!isPlainObject(tags) || Object.keys(tags).length === 0) {
    fail("tags", "must be a non-empty map");
  }
  for (const [key, labels] of Object.entries(tags)) {
    if (!RE.tagKey.test(key)) fail(`tags.${key}`, "key must match " + RE.tagKey);
    if (!isPlainObject(labels)) fail(`tags.${key}`, "must be {en, sv}");
    checkKeys(`tags.${key}`, labels, LANGS);
    for (const lang of LANGS) {
      const v = labels[lang];
      if (!isNonEmptyString(v)) fail(`tags.${key}.${lang}`, "label is required");
      if (/[<>]/.test(v)) fail(`tags.${key}.${lang}`, "label may not contain < or >");
    }
  }
}

function checkDir(where, dir) {
  if (typeof dir !== "string") fail(where, "must be a string");
  if (dir === "") return;
  if (dir.startsWith("/") || dir.startsWith("\\")) fail(where, "must be relative");
  for (const seg of dir.split(/[\\/]/)) {
    if (seg === "" || seg === "." || seg === "..") {
      fail(where, `invalid path segment in ${JSON.stringify(dir)}`);
    }
    if (!RE.dirSegment.test(seg)) {
      fail(where, `segment ${JSON.stringify(seg)} must match ${RE.dirSegment}`);
    }
  }
}

function checkTutorial(t, i, tags, sourceNames, seenSlugs) {
  const where = `tutorials[${i}]`;
  if (!isPlainObject(t)) fail(where, "must be a map");

  const { source, slug, tag } = t;
  if (!isNonEmptyString(source) || !sourceNames.includes(source)) {
    fail(where, `source must be one of ${sourceNames.join(", ")}, got ${JSON.stringify(source)}`);
  }
  if (!isNonEmptyString(slug) || !RE.slug.test(slug)) {
    fail(where, `slug must match ${RE.slug}, got ${JSON.stringify(slug)}`);
  }
  const w = `tutorials[${i}] (${slug})`;
  if (seenSlugs.has(slug)) fail(w, "duplicate slug");
  seenSlugs.add(slug);
  if (!isNonEmptyString(tag) || !(tag in tags)) {
    fail(w, `tag must be one of ${Object.keys(tags).join(", ")}, got ${JSON.stringify(tag)}`);
  }

  checkKeys(w, t, ["source", "slug", "tag", ...FIELDS[source]]);

  if (source === "gdrive") {
    if (!("docs" in t)) fail(w, "gdrive entries need a docs map");
    checkLangMap(`${w}.docs`, t.docs, RE.docId, "a Google Doc id");
  }

  if (source === "github") {
    if (!isNonEmptyString(t.repo) || !RE.repo.test(t.repo)) {
      fail(`${w}.repo`, `must be https://github.com/<owner>/<repo>[.git], got ${JSON.stringify(t.repo)}`);
    }
    if ("ref" in t && (!isNonEmptyString(t.ref) || !RE.ref.test(t.ref))) {
      fail(`${w}.ref`, `must match ${RE.ref}, got ${JSON.stringify(t.ref)}`);
    }
    if ("dir" in t) checkDir(`${w}.dir`, t.dir);
    if ("files" in t) checkLangMap(`${w}.files`, t.files, RE.file, "a bare *.md filename");
  }
}

// Validates the parsed YAML. `sourceNames` is Object.keys(SOURCES) from
// tutorials.config.js. Returns the data unchanged; throws DataError on the
// first problem.
export function validateData(data, sourceNames) {
  if (!isPlainObject(data)) fail("root", "must be a map with tags and tutorials");
  checkKeys("root", data, ["tags", "tutorials"]);
  if (!("tags" in data)) fail("root", "missing tags");
  if (!("tutorials" in data)) fail("root", "missing tutorials");

  checkTags(data.tags);

  if (!Array.isArray(data.tutorials)) fail("tutorials", "must be a list");
  const seen = new Set();
  data.tutorials.forEach((t, i) =>
    checkTutorial(t, i, data.tags, sourceNames, seen),
  );
  return data;
}
