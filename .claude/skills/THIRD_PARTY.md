# Third-party agent skills

Project-scoped skills, loaded by Claude Code in every session on this repository.

| Skills | Source | Licence |
|---|---|---|
| 25 skills: `spec-driven-development`, `planning-and-task-breakdown`, `incremental-implementation`, `idea-refine`, `interview-me`, `context-engineering`, `using-agent-skills`, `test-driven-development`, `debugging-and-error-recovery`, `browser-testing-with-devtools`, `code-review-and-quality`, `code-simplification`, `doubt-driven-development`, `constraint-driven-development`, `security-and-hardening`, `performance-optimization`, `shipping-and-launch`, `ci-cd-and-automation`, `observability-and-instrumentation`, `api-and-interface-design`, `frontend-ui-engineering`, `git-workflow-and-versioning`, `deprecation-and-migration`, `documentation-and-adrs`, `source-driven-development` | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) (copied verbatim, Nov 2026) | MIT © Addy Osmani |
| `graphify` | [Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify), written by `graphify install --project` (graphifyy 0.9.120) | Apache-2.0 |

`graphify` needs its CLI: `pip install graphifyy`. The hooks in `.claude/settings.json`
are skipped when the CLI is not installed, so sessions without it are unaffected.

Update the addyosmani skills by re-copying `skills/<name>/` from the upstream repository;
update graphify with `pip install -U graphifyy && graphify install --project`.

`ponytail` and `find-skills` are not vendored here: they are enabled on the account
(claude.ai) and load in every session already.
