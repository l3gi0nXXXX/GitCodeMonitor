# GCM GitCode Review Domain Model V1

`contractVersion`: `gcm-metis-gitcode-review-v1`

## AuthorIdentityV1

Fields: `login`, `displayName`, `url`, `id`, `emails`, `emailSources`, `emailResolveStatus`, `corporateDomainMatched`, `corporateDomain`, `decision`, `diagnostics`.

Resolution order: webhook `user`, `author`, `object_attributes.author`, `merge_request.author`, `pull_request.author`, `issue.author`, `note.author`; email candidates include `email`, `mail`, `public_email`, `emails[]`, and commit author email fields. If email lookup fails or is absent, GCM continues with `decision=process`.

Corporate policy: any email ending with `@huawei.com` or `@h-partners.com`, case-insensitive, yields `decision=record_only`.

## RepoTeamLeaderV1

Fields: `team`, `teamLeaderStatus`, `teamLeaders[]`. A leader has `mention`, `login`, and `url`. Source is `Cangjie/community/team/repo_list.md`.

## CodeownerV1

Fields: `codeownerStatus`, `codeowners[]`, `changedFiles`, `changedFilesTruncated`. A codeowner has `mention`, `login`, and `url`. Source is `.gitcode/CODEOWNERS`; invalid owner tokens are diagnostics and are not emitted as owners.

## Issue Fields

`issueKind` is one of `bug`, `feature-request`, `question`, or `unknown`.

Bug fields include `cjcVersion` and checked `branchVersions`. Feature and question issues carry sanitized body content and branch data when available.

## PR Fields

PR fields include `prTemplate`, `changeTypes`, `selfCheck`, `relatedIssues`, and changed file facts. Chinese and English template labels are accepted.

## Comment Fields

Comment events use `event.type=comment`; `commentId` and comment body are separate from parent issue or PR body.
