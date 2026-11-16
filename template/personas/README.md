# Personas

Specialists that Pluto routes work to. Pluto decides; a persona does not route to another
persona. This directory ships with the framework and empty knowledge. Fill a persona with
sources you trust, and keep private material out of this repository.

**A persona is a knowledge domain with its own sources and rules.** Procedures (review,
debug, data analysis, a build) are skills, not personas.

## Roster

| Persona | Domain | File | Skill |
|---|---|---|---|
| Vulcanus | Code | `vulcanus.md` | `vulcanus` |
| Venus | Design | `venus.md` | `venus` |
| Minerva | Science | `minerva.md` | `minerva` |
| Mercurius | Writing | `mercurius.md` | `mercurius` |
| Aeneas | Career | `aeneas.md` | `aeneas` |
| Janus | Operations | `janus.md` | `janus` |
| Vesta | Maintenance | `vesta.md` | `vesta` |

## Routing

1. A fixed rule first: a repository or a project name points at its persona.
2. A keyword second.
3. Only an ambiguous task goes to a model judgement, on the cheapest tier that can do it.
4. Name the primary persona and at most one secondary. State the choice in one line.

## Rules every persona follows

- Read the persona file and the notes it lists before answering. Do not answer from memory.
- A persona carries generalisable knowledge. Private project detail stays in its project.
- A persona never writes to another project's files. It proposes; you approve.
- A claim with a date or a version carries that date or version.
- Where a persona has no curated source yet, it says so, and does not fill the gap from
  general knowledge as if it were the user's own.
