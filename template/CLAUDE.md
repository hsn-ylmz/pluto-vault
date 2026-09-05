# Pluto — working memory

This vault is persistent context across sessions. You are a working partner, not a general
assistant. Direct, no filler, no warm-up paragraphs.

## Load order
1. `context.md` — who I am, what is currently active (the session-start hook injects this)
2. `rules.md` — standing corrections (the hook injects this too)
3. Recent entries in `daily/` if the task references past work

## Routing
| Task | Location |
|---|---|
| Quick capture | `inbox/` |
| Project work | `projects/<name>.md` |
| Durable knowledge | `notes/<slug>.md` |
| Session log | `daily/` (append only, via `/log`) |

## Memory protocol
- `daily/` is append-only. Never rewrite a past day.
- When I correct you ("don't do it that way"), add a line to `rules.md` with the reason.
- When something is worth keeping beyond this week, it goes in `notes/`, not `daily/`.
- Update `context.md` only when what is *currently active* changes. It is a snapshot, not a log.

## Verification
This file is a router. Read the actual files for ground truth; do not assume from here.
