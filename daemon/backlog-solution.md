# Backlog Resolution Proposal

## Problem

The current review pipeline has two failure modes:

1. Submitted signals are effectively opaque until review completes, so correspondents cannot tell whether work is waiting, stale, or skipped.
2. Daily capacity is being enforced by `reviewed_at` timing instead of the signal's filing date, which lets older backlog items consume today's approval slots.

That combination creates the backlog problem users are seeing: submissions exist, but the system does not clearly expose queue state or fair daily capacity usage.

## Proposed Fix

### 1. Add a real queue API

Expose a dedicated queue endpoint, for example `GET /api/signals/queue`, with these fields:

- `queueDepth`
- `oldestPendingMinutes`
- `avgReviewTimeMinutes`
- `reviewedLastHour`
- `perBeatBreakdown`
- `capRemainingToday`
- `staleSubmittedCount`

This should be read-only and cheap to compute from the existing signals table.

### 2. Count daily caps by filing day, not review day

The approval cap should be enforced against the signal's Pacific-day filing bucket, not against `reviewed_at`.

Implementation rule:

- `created_at` determines the day bucket.
- `reviewed_at` determines whether the item has been processed.
- A backlog item from yesterday must not consume today's approval capacity unless the product explicitly wants that behavior.

If the current product intent is to keep caps tied to review time, then the UI and API must say that explicitly. Right now the behavior reads like a bug.

### 3. Surface queue state in statuses

Keep the existing statuses, but make the queue classification explicit:

- `submitted` -> `in-backlog`
- `in_review` -> `in-review`
- `approved` -> `approved`
- `brief_included` -> `public`
- `rejected` -> `rejected`

The watcher and dashboard should show queue state separately from site visibility.

### 4. Add stale-item triage

Anything older than a threshold, such as 12 or 24 hours, should be flagged as stale and moved into a triage view.

Suggested behavior:

- flag in the queue API
- add a stale badge in the dashboard
- prioritize stale items in reviewer order
- optionally notify maintainers when backlog age crosses a threshold

## Minimal Data Model Changes

- Index `signals(status, created_at)`
- Index `signals(status, reviewed_at)`
- Index `signals(beat_slug, created_at)`
- Persist Pacific-day bucket for deterministic cap accounting if timezone conversion is expensive

## Acceptance Criteria

- The dashboard can tell whether a submitted signal is still in backlog.
- A developer can see queue depth and oldest pending age without querying raw rows manually.
- A signal filed today cannot be blocked by yesterday's backlog unless that is an intentional policy.
- Daily approval counts are reproducible from filing-day data and match the product rule.

## Suggested Rollout

1. Ship the queue endpoint and dashboard visibility first.
2. Add the filing-day cap calculation behind a feature flag.
3. Backfill one day of data and compare the old and new counts.
4. Turn on the new cap rule after the numbers match the intended policy.

## Why This Solves the User Pain

The user complaint is not just "the site is slow." It is that the system hides whether a signal is waiting, and the cap logic can make fresh submissions lose out to backlog timing. Making queue depth visible and fixing cap accounting addresses both problems directly.