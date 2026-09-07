#!/usr/bin/env node
// Validate tutorials.data.yaml and exit non-zero on the first problem.
//
// Loading tutorials.config.js reads the data file and runs it through
// scripts/data-schema.js, so this wrapper only has to surface the outcome
// with a clean exit code. CI runs it before syncing so a bad data file fails
// on a one-line message instead of deep inside a clone.
//
//   node scripts/validate-data.js                      # the real file
//   TUTORIALS_DATA=some.yaml node scripts/validate-data.js   # any other file

import { DataError } from "./data-schema.js";

try {
  const { DATA_PATH, TAGS, TUTORIALS } = await import("../tutorials.config.js");
  console.log(
    `✓ ${DATA_PATH}: ${Object.keys(TAGS).length} tag(s), ${TUTORIALS.length} tutorial(s)`,
  );
} catch (err) {
  // DataError = schema violation, YAMLException = unparsable file (including
  // duplicate keys); anything else is a bug worth the full stack.
  const clean = err instanceof DataError || err?.name === "YAMLException";
  console.error(`✗ ${clean ? err.message : err.stack || err}`);
  process.exit(1);
}
