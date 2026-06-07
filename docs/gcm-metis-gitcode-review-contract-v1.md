# GCM/Metis GitCode Review Contract v1

This document fixes the writeback part of the GCM/Metis GitCode review contract.

## Generated Reply Input

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

## Response

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

GCM must not append self markers, hidden HTML markers, bot attribution, or role labels to GitCode comments. Internal audit/state may store hashes, decisions, and diagnostic statuses.
