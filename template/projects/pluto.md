---
name: pluto
path: {{VAULT}}
---

## Status
the vault itself.

This file is also the format documentation. `path:` in the frontmatter is the only required
field — it is what `pluto pluto` resolves, what `pluto --status` inspects, and what a free-text
question uses to decide which project your cwd belongs to. The first non-empty line under
`## Status` becomes the description in `pluto --list`.

Everything below the frontmatter is free prose. This is a normal note that happens to be
machine-readable at the top, which is the point: there is no separate config file listing your
projects, so the list can never disagree with your notes.

Add your own with `pluto --create`, or by copying this file.
