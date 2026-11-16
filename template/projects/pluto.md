---
name: pluto
path: {{VAULT}}
---

## Status
the vault itself.

This file is also the format documentation. `path:` in the frontmatter is the only required
field — it is what the session briefing and the vault session's directory list read, and what
`pluto --status` inspects. The first non-empty line under `## Status` becomes the description
in `pluto --list`. Projects are not command arguments: a new one is started in the conversation.

Everything below the frontmatter is free prose. This is a normal note that happens to be
machine-readable at the top, which is the point: there is no separate config file listing your
projects, so the list can never disagree with your notes.

Add your own by asking in the conversation, or by copying this file.
