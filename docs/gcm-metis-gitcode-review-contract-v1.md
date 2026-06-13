# GCM Metis GitCode Review Contract V1

`contractVersion`: `gcm-metis-gitcode-review-v1`

This document fixes the contract boundary between GitCodeMonitor and Metis for GitCode issue, pull request, comment review, Metis draft generation, and GCM writeback.

## Ownership

| Area | Owner | Rule |
|---|---|---|
| GitCode webhook receive, authentication, queue, dedupe, event state | GitCodeMonitor | Metis must not parse raw GitCode webhook payload as the source of truth. |
| Author email classification and corporate record-only policy | GitCodeMonitor | Record-only author domains are configured by `gitcode.authorPolicy.recordOnlyEmailDomains`; default is empty, so no author is filtered unless configured. Matching events are recorded only and must not call Metis. |
| Team leader, CODEOWNERS, issue template, PR template lookup | GitCodeMonitor | Lookup failures are diagnostics, not hard failures. GCM reads `Cangjie/community/team/repo_list.md`, target `.gitcode/CODEOWNERS`, and PR changed files before accepted event emission. |
| Maintainer context store and maintainer email notification | GitCodeMonitor | GCM persists maintainer context by `eventId/sourceEventId`, resolves maintainer email from explicit context email, GitCode user API, or addressBook fallback, appends natural maintainer footer, and sends optional SMTP email after successful GitCode writeback. Metis must not parse repo list/CODEOWNERS, query GitCode user email, cache maintainer email, or send maintainer email. |
| LLM, CKB, source workspace, external PR review engine adapter, draft generation | Metis | GCM must not call LLM, CKB, or PR review engine for user-facing reply generation. Metis owns only the adapter boundary for the external PR review engine. |
| GitCode official API writeback | GitCodeMonitor | Metis returns a generated reply; GCM owns gate, natural maintainer mention sentence, internal writeback audit state, and API call. |
| GitCode writeback scope | GitCodeMonitor | GCM owns writeback scope evaluation. Metis does not directly decide whether a GitCode repo or org is allowed to receive writeback. |

## Referenced Domain Documents

| Document | Purpose |
|---|---|
| `docs/gcm-gitcode-review-domain-model-v1.md` | Defines author, team leader, codeowner, issue, PR, and comment domain models. |
| `docs/gcm-gitcode-review-footer-format-v1.md` | Defines natural maintainer mention sentence rules, template pool, duplicate prevention, and forbidden user-visible text. |

## GCM to Metis Event

Capability: `gitcode.event.accepted`

GCM emits `gitcode.event.accepted` with legacy top-level scan fields and a structured `reviewRequest`. Metis must prefer `reviewRequest` when present. Legacy fields remain for old scan/reconcile consumers.

Required top-level fields:

- `jobId`, `eventId`, `repo`, `kind`, `number`, `author`, `url`, `title`, `content`, `contentRedacted`, `truncated`
- `contractVersion`
- `reviewRequest`

Required `reviewRequest` fields:

- `contractVersion`, `jobId`, `eventId`, `repo`
- `event.type`, `event.itemKind`, `event.number`, `event.commentId`, `event.action`
- `delivery.eventHeader`, `delivery.action`, `delivery.deliveryId`
- `author.login`, `author.displayName`, `author.url`, `author.id`, `author.emails`, `author.emailSources`, `author.emailResolveStatus`, `author.corporateDomainMatched`, `author.corporateDomain`, `author.decision`
- `maintainers.team`, `maintainers.teamLeaderStatus`, `maintainers.teamLeaders`, `maintainers.codeownerStatus`, `maintainers.codeowners`
- `templates.issueKind`, `templates.templateStatus`, `templates.fields.cjcVersion`, `templates.fields.branchVersions`
- `pr.changedFiles`, `pr.changedFilesTruncated`, `pr.prTemplate`, `pr.changeTypes`, `pr.selfCheck`, `pr.relatedIssues`
- `content.title`, `content.body`

For comment events, GCM also sends `reviewRequest.context` when the event is accepted through the webhook processor. Older scan/reconcile producers may omit it; Metis must keep legacy compatibility, but must treat missing comment context as degraded when generating a user-facing draft.

`reviewRequest.context` fields:

- `status`: `resolved` when parent detail and comment context were built without fetch failures; `degraded` when detail/comments fetch failed, current comment ordering is uncertain, or fallback data was used.
- `parent`: parent Issue/PR facts with `kind`, `number`, `title`, `body`, `url`, `author`, `authorUrl`, and `source`. `source` is `api`, `webhook_envelope`, or `event`.
- `triggerComment`: the current comment that triggered the accepted event, with `id`, `body`, `url`, `author`, `authorUrl`, `createdAt`, `createdAtMs`, and `updatedAtMs`.
- `previousComments`: comments before `triggerComment` after GCM ordering. If GitCode omits created-time metadata, GCM preserves API order and adds `order_degraded`.
- `previousCommentsTotal`: total previous comments available before safety truncation.
- `previousCommentsIncluded`: previous comments included in this payload after safety truncation.
- `truncated`: `true` when parent body, trigger body, or previous comments were shortened or omitted to fit the GCM context budget.
- `diagnostics`: redacted diagnostic strings such as `detail_fetch_failed:forbidden`, `comments_fetch_failed:rate_limited`, `order_degraded`, or `current_comment_not_found`.

GCM builds this context before emitting an accepted comment frame, but only after record-only author policy and self-echo checks have passed. Record-only and self-echo events must not fetch context and must not emit `gitcode.event.accepted`.

GCM context is factual GitCode data only. GCM must not call LLM/model/session APIs or write prompts. Metis owns prompt construction and draft generation.

Validation statuses:

- `ok`
- `contract_version_missing`
- `contract_version_unsupported`
- `payload_contains_secret`
- `payload_contains_local_path`
- `repo_missing`
- `invalid_json`

Secrets, authorization headers, cookies, tokens, passwords, bot tokens, and local filesystem paths must not appear in contract payloads or diagnostics.

## Corporate Record-Only

If author email resolution finds any email ending with a suffix explicitly configured in `gitcode.authorPolicy.recordOnlyEmailDomains`, GCM records the event as `record_only`, marks it seen, marks the webhook delivery processed, and does not emit `gitcode.event.accepted`.

The default `recordOnlyEmailDomains` value is `[]`. Missing `gitcode.authorPolicy`, missing `recordOnlyEmailDomains`, or an empty list means no corporate record-only filtering is applied.

If author email resolution fails, GCM records `emailResolveStatus=email_unavailable` and treats the author as external/unknown so the event can still be reviewed.

## Metis to GCM Generated Reply

Capability: `gitcode.writeback.apply_result`

`gitcode.writeback.apply_result` accepts the current `GitCodeGeneratedReplyV1` shape and the legacy `GcmWritebackRequest` shape.

Required fields:

- `eventId`
- `repo`, in `org/repo` form
- `kind`, one of `issue`, `pr`, or `comment`
- `number`
- `url`
- `draft`
- `safety`
- `needsHumanReview`

Compatible maintainer context fields may be provided at top level, under `maintainers`, or under `reviewRequest.maintainers`:

- `teamLeaders` or `teamLeaderMentions`
- `codeowners` or `codeownerMentions`

Only parsed valid GitCode mentions are used for the final comment.

New Metis integrations should not send maintainer facts back. GCM resolves writeback maintainer context in this priority order:

```text
GCM context store > GCM deterministic fallback > payload_compat > unavailable
```

`payload_compat` exists only for older payloads and tests. The normal Metis payload remains minimal: event identity, repo target, draft, safety, and human-review flags.

## Writeback Gate

GCM must not call the GitCode writer when any of these conditions holds:

- malformed payload
- `draft` is empty
- `draft` exceeds the GCM writeback limit
- `autoReply=false`
- `dryRun=true`
- repo is not allowlisted
- `safety` is rejected
- `needsHumanReview=true`
- duplicate reply
- draft contains secrets
- draft contains local machine paths

## Writeback Scope

`monitor.writebackScope` is the contract field for GitCode writeback scope. GCM owns this gate and evaluates it before calling the GitCode official API writer. Metis only returns generated reply content and safety metadata through `gitcode.writeback.apply_result`; Metis must not directly judge whether a GitCode repo or org is allowed to receive writeback.

Supported fields:

| Field | Meaning | Match target |
|---|---|---|
| `monitor.writebackScope.allowedOrgs` | Organizations allowed for writeback | `owner`, case-insensitive exact match |
| `monitor.writebackScope.allowedRepos` | Repositories allowed for writeback | `owner/repo`, case-insensitive exact match |
| `monitor.writebackScope.deniedRepos` | Repositories excluded from writeback | `owner/repo`, case-insensitive exact match |
| `monitor.repoAllowlist` | Legacy diagnostic field | Parsed for validation and migration visibility only; it no longer authorizes writeback. Use `writebackScope.allowedRepos` instead. |

Scope priority is:

```text
deniedRepos > allowedRepos > allowedOrgs > default deny
```

`deniedRepos` has the highest priority. A repository listed in `deniedRepos` must not be written back even if its owner is present in `allowedOrgs` or the repository is present in `allowedRepos`.

## Writeback Response

`gitcode.writeback.apply_result` returns a structured payload:

- `ok`
- `status`
- `writerCalled`
- `posted`
- `retryable`
- `replyUrl`
- `maintainerMentionAppended`
- `teamLeaderCount`
- `codeownerCount`
- `contextSource`: `store`, `deterministic_fallback`, `payload_compat`, or `unavailable`
- `emailNotificationStatus`: `email_disabled`, `email_unavailable`, `sent`, or `send_failed`
- `emailSentCount`
- `emailFailedCount`
- `emailRetryable`

The service plugin protocol may carry this as JSON inside a response frame. User-facing Metis renderers are responsible for turning it into human-readable text.

The response must not include recipient email addresses, GitCode user API raw responses, SMTP passwords or authorization codes, `passwordEnv` values, raw payloads, or email bodies.

## Comment Body Invariants

GCM must not append self markers, hidden HTML markers, bot attribution, role labels, `auto-reply`, or `gitcodemonitor` branding to GitCode comments. Internal audit/state may store hashes, decisions, and diagnostic statuses.
