# Skills and instructions

## Instructions

`AGENTS.md` files hold standing instructions that every run in a project gets in its system prompt. zeta collects the user's `~/.config/zeta/AGENTS.md` first, then each `AGENTS.md` from the filesystem root down to the project directory, in that order. They are read fresh for every run. Keep them short: everything in them costs context on every request. Put long or occasional material in a skill.

## Skills

A skill is a directory with a `SKILL.md`: instructions, and any files they refer to, that the model loads only when a task needs them. Only each skill's name and description sit in the system prompt; the `skill` tool loads the rest on demand.

Skills are discovered under these roots, in priority order; a later root replaces a skill of the same name:

1. `~/.agents/skills/`
2. `~/.config/zeta/skills/`
3. `<project>/.agents/skills/`
4. `<project>/.zeta/skills/`

A `SKILL.md` counts in any subdirectory of a root (`skills/<name>/SKILL.md`, or deeper), not in the root itself. Skills are read fresh for every run; no reload is needed.

```markdown
---
name: release-notes
description: Write release notes from the git log. Use when the user asks for release notes or a changelog entry.
---

1. Run `git log --oneline <previous tag>..HEAD`.
2. Group the commits by type, following `template.md` in this directory.
3. ...
```

- `name`: lowercase letters, digits and single hyphens, not starting or ending with a hyphen, at most 64 bytes.
- `description`: at most 1024 bytes, on one line or as a YAML `>` or `|` block. It is all the model sees until it loads the skill, so say what the skill does and when to use it.
- The frontmatter must open the file and close with `---`; other keys are ignored. A file without a valid `name` and `description` is skipped.
- The `skill` tool returns the body with the skill's directory (`Base directory: …`), so the body can name other files in that directory by relative path; the model reads them with `read`.

Discovery descends at most eight directory levels, opens at most 4096 directories, and keeps at most 256 skills; a skill file is limited to 1 MiB. The skill list in the prompt is capped at 32 KiB. Skills beyond a limit are skipped and the server logs a warning. `GET /registry` lists the skills a run in a project gets, with their paths. Permission rules match the `skill` tool against the skill name.

zeta ships one built-in skill, `zeta`: the index of these documentation pages, loaded from the extracted docs directory. A discovered skill named `zeta` replaces it.
