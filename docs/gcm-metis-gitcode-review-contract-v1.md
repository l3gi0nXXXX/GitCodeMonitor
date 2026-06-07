# GCM Metis GitCode Review Contract V1

`contractVersion`: `gcm-metis-gitcode-review-v1`

This document fixes the contract boundary between GitCodeMonitor and Metis for GitCode issue, pull request, comment review, Metis draft generation, and GCM writeback.

## Ownership

| Area | Owner | Rule |
|---|---|---|
| GitCode webhook receive, authentication, queue, dedupe, event state | GitCodeMonitor | Metis must not parse raw GitCode webhook payload as the source of truth. |
| Author email classification and corporate record-only policy | GitCodeMonitor | Corporate author events are recorded only and must not call Metis. |
| Team leader, CODEOWNERS, issue template, PR template lookup | GitCodeMonitor | Lookup failures are diagnostics, not hard failures. |
| LLM, CKB, source workspace, external PR review engine adapter, draft generation | Metis | GCM must not call LLM, CKB, or PR review engine for user-facing reply generation. Metis owns only the adapter boundary for the external PR review engine. |
| GitCode official API writeback | GitCodeMonitor | Metis returns a generated reply; GCM owns gate, natural maintainer mention sentence, internal writeback audit state, and API call. |

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

If author email resolution finds any email ending with `@huawei.com` or `@h-partners.com`, GCM records the event as `record_only`, marks it seen, marks the webhook delivery processed, and does not emit `gitcode.event.accepted`.

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

The service plugin protocol may carry this as JSON inside a response frame. User-facing Metis renderers are responsible for turning it into human-readable text.

## Comment Body Invariants

GCM must not append self markers, hidden HTML markers, bot attribution, role labels, `auto-reply`, or `gitcodemonitor` branding to GitCode comments. Internal audit/state may store hashes, decisions, and diagnostic statuses.
