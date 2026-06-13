# GCM GitCode Review Domain Model V1

`contractVersion`: `gcm-metis-gitcode-review-v1`

## AuthorIdentityV1

Fields: `login`, `displayName`, `url`, `id`, `emails`, `emailSources`, `emailResolveStatus`, `corporateDomainMatched`, `corporateDomain`, `decision`, `diagnostics`.

Resolution order: webhook `user`, `author`, `object_attributes.author`, `merge_request.author`, `pull_request.author`, `issue.author`, `note.author`; email candidates include `email`, `mail`, `public_email`, `emails[]`, and commit author email fields. If email lookup fails or is absent, GCM continues with `decision=process`.

Corporate policy is driven by `gitcode.authorPolicy.recordOnlyEmailDomains`. The default domain list is empty, so no author is record-only unless the user explicitly configures one or more email suffixes. Matching is case-insensitive suffix matching after normalizing entries such as `huawei.com` to `@huawei.com`.

## RepoTeamLeaderV1

Fields: `team`, `teamLeaderStatus`, `teamLeaders[]`. A leader has `mention`, `login`, and `url`. Source is `Cangjie/community/team/repo_list.md`.

GCM fetches the file through the configured GitCode API transport before emitting `gitcode.event.accepted`. The contents API may return raw text or `content` with base64 encoding; both forms are normalized by GCM. Email addresses are not guessed from `login`.

## CodeownerV1

Fields: `codeownerStatus`, `codeowners[]`, `changedFiles`, `changedFilesTruncated`. A codeowner has `mention`, `login`, and `url`. Source is `.gitcode/CODEOWNERS`; invalid owner tokens are diagnostics and are not emitted as owners.

For PR events and PR comments, GCM fetches PR changed files with the GitCode pull request files API and matches them against `.gitcode/CODEOWNERS`. For issue events and issue comments, codeowner status is `not_applicable` unless an already persisted parent PR context is used.

## MaintainerNotificationEmailV1

Maintainer email recipients are resolved by GCM in this order:

1. Explicit email fields already present in the GCM maintainer context.
2. GitCode user API lookup: `GET {gitcode.baseUrl}/users/{login}` where `login` comes from the maintainer mention or login.
3. Optional `gitcode.maintainerNotification.email.addressBook` fallback when `userLookup.fallbackToAddressBook=true`.

GCM may query GitCode/AtomGit user profile APIs for email, but it must not guess an address by concatenating a login and a domain. User API responses are parsed only for email fields such as `email`, `mail`, `public_email`, `publicEmail`, `emails`, `email_addresses`, and `emailAddresses`; `github_account` is not a recipient email source.

The address book maps a maintainer mention or login to one or more fallback email addresses. Addresses from every source are normalized to lowercase, deduplicated, and optionally restricted by `allowedDomains`. Email notification is disabled by default and is sent only after GitCode comment writeback succeeds.

GCM stores maintainer context by `eventId/sourceEventId` in its context store. Stored data is limited to repo target, mention/email/status metadata, changed-file paths, and timestamps; it must not contain raw webhook payloads, generated email bodies, user API raw responses, tokens, SMTP passwords, or authorization codes.

## Issue Fields

`issueKind` is one of `bug`, `feature-request`, `question`, or `unknown`.

Bug fields include `cjcVersion` and checked `branchVersions`. Feature and question issues carry sanitized body content and branch data when available.

## PR Fields

PR fields include `prTemplate`, `changeTypes`, `selfCheck`, `relatedIssues`, and changed file facts. Chinese and English template labels are accepted.

## Comment Fields

Comment events use `event.type=comment`; `commentId` and comment body are separate from parent issue or PR body.
