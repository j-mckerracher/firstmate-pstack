# Work-class dispatch plan

Configure existing task-based dispatch so each class of work has an independently editable harness, runtime provider/model, and effort. Firstmate infers the class from the task; an explicit class or per-task profile override takes precedence.

1. Confirm the existing dispatch schema, precedence, and worker-launch integration with the reference librarian. Complete: existing natural-language rules support this without runtime changes.
2. Complete: extended local `config/crew-dispatch.json` with debugging, implementation, research, planning, review, testing, documentation, and maintenance rules. Seeded each with the existing default, preserved billing fallback rules and the default, and explained class overrides and runtime provider syntax.
3. Complete: delegated documentation and reusable example changes using the existing schema. Added the required documentation audience entry.
4. Complete: JSON syntax/structure and preservation assertions pass. Both local config and example pass the exact bootstrap jq schema validator in ordinary-dispatch mode, without executing bootstrap. Documentation audience/link checks pass with the new example included in a temporary Git index; the real index is unchanged. The optional broad dispatch regression passed its completed cases, including explicit profile launch flags, but was stopped before completion because of its long runtime. Its initial sandbox attempt failed fixture process-identity initialization; the subsequent run used the required process access. No runtime code was changed.

Runtime provider is encoded in `model` as `provider/model` for multi-provider harnesses. The optional `provider` property belongs to quota accounting and must not be repurposed.

Adapter references: `.agents/skills/harness-adapters/references/common/model-and-effort.md`, `.agents/skills/harness-adapters/references/common/dispatch.md`, then `.agents/skills/harness-adapters/references/harness/omp.md`.
