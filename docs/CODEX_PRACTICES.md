# Codex repository practices

Researched 2026-09-08 against official OpenAI and GitHub documentation. These are project choices informed by the sources, not a claim that every repository needs the same scaffolding.

| Practice | Implementation here | Source |
| --- | --- | --- |
| Discoverable, scoped instructions | Short root AGENTS.md, with iOS and firmware detail in nested files | [AGENTS.md discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md) |
| Separate durable context from task prompts | STATUS records implemented behavior and pending verification; DEVELOPMENT supplies commands; the user's new prompt supplies scope | [AGENTS.md guidance](https://learn.chatgpt.com/docs/agent-configuration/agents-md) |
| Isolate concurrent code changes | Git worktrees and checkout-specific build directories; one owner per hardware rig | [Worktrees](https://learn.chatgpt.com/docs/environments/git-worktrees) |
| Reproducible environments | Explicit pinned SDK bootstrap, lockfile, unsigned build, shared Xcode scheme and CI | [Cloud environment setup and caching](https://learn.chatgpt.com/docs/environments/cloud-environment) |
| Add specialized skills only when useful | No redundant project skill yet; stable instructions and scripts cover current workflows. Future reusable procedures can live in .agents/skills | [Skill discovery](https://learn.chatgpt.com/docs/build-skills) |
| Limit CI privileges | Read-only contents token, full-SHA checkout action, no signing secrets or privileged PR trigger | [GitHub Actions secure use](https://docs.github.com/en/actions/reference/security/secure-use) |

Codex discovers instructions from broader scopes down to the working directory; nearer files refine their scope. Keep this chain small and actionable. Large design histories belong in referenced docs, not always-loaded instructions. Worktrees isolate files, but not physical boards, device installs or external services.

The cloud setup process is distinct from the task shell and supports cached environments and maintenance scripts. This repository supplies portable commands but cannot make Xcode or an attached iPhone available in a Linux container. Configure the appropriate host rather than claiming those tests were run remotely.

No global permission changes, unrestricted execution configuration or model override is committed. Future chats retain their host's existing settings and authorization rules.
