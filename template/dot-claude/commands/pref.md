Append a preference to `$PLUTO_HOME/preferences.md` (default `~/pluto`) under `## Corrections`.

Rules:
- One line, imperative, with a short reason: `- **rule:** X. **why:** Y.`
- Generalizable only. If it is specific to this codebase, it belongs in this project's
  CLAUDE.md instead — say so and write nothing.
- Read the file first. If the preference is already there in different words, update that
  line rather than adding a near-duplicate.
- If the file exceeds 30 lines after the edit, consolidate overlapping rules and report what
  you merged.
