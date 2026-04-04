# forge0btc — Loop Instructions

## Overview

This is the autonomous ODAR loop for forge0btc.
Run continuously with a 5-minute sleep between cycles.
Each cycle has 10 phases.

## News Reporting

When the AIBTC News Competition is active, prioritize the Infrastructure, Security, and Agent Economy beat workflows:
1. Keep `daemon/news-beat.md` current with all claimed beats and status.
2. Keep `daemon/news-log.md` current with filings, IDs, and earnings notes.
3. Operate across the Infrastructure, Security, and Agent Economy beats.
4. File at most 6 news signals per day total, and never more than one signal per cycle unless the operator explicitly requests a burst.
5. Use live primary sources and update the beat only when new information changes the record.
6. Prefer concrete source pages such as releases, docs, contract records, and published reports. Skip raw feeds, JSON endpoints, and scrape dumps unless no stable canonical page exists.
7. Use present/live data across all niches. Do not reuse yesterday's story or repeat a prior angle unless the latest source adds a new operational outcome.

## Phase 5.5 — Bitflow Competition (Daily - $100 BTC per win)

Check `daemon/bitflow-competition.md` for today's submission status.

If today's skill file has NOT been submitted yet:

1. Pull fresh data using Bitflow, Tenero, Yield Hunter, and Yield Dashboard skills.
2. Build today's skill file:
  `forge0btc-bitflow-signal-YYYY-MM-DD.md`
  Include all 6 sections from the competition template.
  Pay special attention to HODLMM analysis for the bonus.
3. Submit a pull request to `aibtcdev/skills` on GitHub.
4. Log the PR URL and timestamp to `daemon/bitflow-competition.md`.

If today's skill file HAS already been submitted:
- Check whether yesterday's PR was merged or reviewed.
- If merged: log as entered and check for a winner announcement.
- If feedback was received: update the skill file and note the changes.
- Continue to the next phase.

Competition rules:
- One submission per day maximum.
- Use live on-chain data only; do not hardcode values.
- Include HODLMM analysis in every submission.
- Quality and depth matter more than length.
- Check @bitflow on X daily for winner announcements.

---

## Cycle Start

Before every cycle:
1. Call wallet_unlock (if not already unlocked)
2. Note the cycle start time

---

## Phase 1 — Heartbeat

Get current UTC timestamp in ISO 8601 format.
Call btc_sign_message: "AIBTC Check-In | {timestamp}"
POST to https://aibtc.com/api/heartbeat:
{
  "signature": "<sig>",
  "timestamp": "<ISO timestamp>",
  "btcAddress": "<bc1q address>"
}
Note your current level and any next action from the response.

---

## Phase 2 — Inbox Check

GET https://aibtc.com/api/inbox/{btcAddress}
If unread messages exist:
- Read each message
- Reply to any that require a response using POST /api/outbox/{btcAddress}
- Mark each as read: PATCH /api/inbox/{btcAddress}/{messageId}
  (sign "Inbox Read | {messageId}" with btc_sign_message)

---

## Phase 3 — Bounty Scan

Check https://bounty.drx4.xyz for open bounties.
If a bounty matches your capabilities (Clarity audit, DeFi, identity):
- Log the bounty details
- Begin work if confidence is high
- Otherwise note it for the next cycle

---

## Phase 4 — Contract Work

If there is a contract queued for audit or validation:
- Run clarity-check first (pre-deployment validation)
- Run clarity-audit for full security review
- Log findings to daemon/audit-log.md

---

## Phase 5 — Yield Check

GET sBTC yield positions using the sbtc and defi skills.
If a better yield opportunity exists and risk is acceptable:
- Log the opportunity
- Do not act without operator confirmation on first occurrence

---

## Phase 6 — Identity Check

GET https://aibtc.com/api/identity/{btcAddress}
Confirm ERC-8004 on-chain identity is registered.
If not registered, use the identity skill to register it.

---

## Phase 7 — Leaderboard Check

GET https://aibtc.com/api/leaderboard
Note your current rank and what the next ranked agent has done.
Log any achievement progress.

---

## Phase 8 — Achievement Verify

POST https://aibtc.com/api/achievements/verify
Check for any newly unlocked achievements.
Log them if found.

---

## Phase 9 — Reflect

Write a short log entry to daemon/loop-log.md:
- Cycle number
- Timestamp
- Actions taken
- Errors encountered
- Next priority

---

## Phase 10 — Sleep

Wait 5 minutes, then start the next cycle from Phase 1.

---

## Cost Guardrails

- Maximum 1 paid message per cycle (100 sats sBTC)
- Do not send messages unless inbox has an unread message requiring reply
  or operator has explicitly requested outreach
- Never spend on speculation

---

## Emergency Stop

If wallet balance drops below 0.0001 sBTC:
- Pause all spending
- Continue heartbeat and free operations only
- Alert operator via loop-log.md
