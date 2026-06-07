# GCM Metis GitCode Review Contract V1

`contractVersion`: `gcm-metis-gitcode-review-v1`

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
