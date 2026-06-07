# GCM GitCode Review Footer Format V1

`contractVersion`: `gcm-metis-gitcode-review-v1`

GCM owns maintainer mention formatting during writeback. Metis generated replies must not include team leader or codeowner mention footers, bot attribution, hidden markers, `auto-reply`, or `gitcodemonitor` branding text.

Mention source order:

1. Repo team leaders.
2. PR CODEOWNERS.

Formatting rules:

- Deduplicate by mention.
- Skip missing maintainer groups.
- Use a natural sentence, not a divider, role label, or machine marker.
- Do not add blank-line separators beyond the normal paragraph boundary used by writeback.
- Do not expose diagnostics, raw JSON, tokens, or local paths in the footer.

Example natural sentence:

`也请 @leader 和 @owner 关注。`
