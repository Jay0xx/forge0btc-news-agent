---
name: clarity-patterns
description: "Clarity smart contract pattern library — reusable code patterns, contract templates, and design references for building on Stacks."
metadata:
  author: "whoabuddy"
  author-agent: "Arc"
  user-invocable: "false"
  arguments: "list | get | template"
  entry: "clarity-patterns/SKILL.md"
  requires: ""
  tags: "read-only, l2, infrastructure"
---

# Clarity Patterns Skill

Canonical pattern library for Clarity smart contract development on Stacks. All patterns and templates are bundled in this skill — no external dependencies.

This is a doc-only skill. Agents read this file and the colocated reference files directly. The CLI interface documents the planned implementation.

```
bun run clarity-patterns/clarity-patterns.ts <subcommand> [options]
```

## Subcommands

- `list [--category <category>]` — List available patterns and templates (categories: `code`, `registry`, `templates`, `testing`)
- `get --name <pattern-name>` — Return a specific pattern with code and notes
- `template --name <template-name>` — Return a complete contract template with source, tests, and checklist

---

## Code Patterns

### Public Function Template

Standard structure for public functions with guards and error handling.

```clarity
(define-public (transfer (amount uint) (to principal))
  (begin
    (asserts! (is-eq tx-sender owner) ERR_UNAUTHORIZED)
    (try! (ft-transfer? TOKEN amount tx-sender to))
    (ok true)))
```

- Use `try!` for subcalls to propagate errors
- Use `asserts!` for guards before state changes
- Add post-conditions on tx for asset safety

### Standardized Events

Emit structured events for off-chain indexing.

```clarity
(print {
  notification: "contract-event",
  payload: {
    amount: amount,
    sender: tx-sender,
    recipient: to
  }
})
```

- `notification`: string identifier for the event type
- `payload`: tuple with camelCase keys
- Examples: [usabtc-token](https://github.com/USA-BTC/smart-contracts/blob/main/contracts/usabtc-token.clar), [ccd002-treasury-v3](https://github.com/citycoins/protocol/blob/main/contracts/extensions/ccd002-treasury-v3.clar)

### Error Handling with Match

Handle external call failures gracefully.

```clarity
(match (contract-call? .other fn args)
  success (ok success)
  error (err ERR_EXTERNAL_CALL_FAILED))
```

### Bit Flags for Status/Permissions

Pack multiple booleans into a single uint.

```clarity
(define-constant STATUS_ACTIVE (pow u2 u0))   ;; 1
(define-constant STATUS_PAID (pow u2 u1))     ;; 2
(define-constant STATUS_VERIFIED (pow u2 u2)) ;; 4

;; Pack multiple flags: (+ STATUS_ACTIVE STATUS_PAID) → u3
;; Check flag: (> (bit-and status STATUS_ACTIVE) u0)
;; Set flag: (var-set status (bit-or (var-get status) NEW_FLAG))
;; Clear flag: (var-set status (bit-and (var-get status) (bit-not FLAG)))
```

Examples: [aibtc-action-proposal-voting](https://github.com/aibtcdev/aibtcdev-daos/blob/main/contracts/dao/extensions/aibtc-action-proposal-voting.clar)

### Multi-Send Pattern

Send to multiple recipients in one transaction using fold.

```clarity
(define-private (send-maybe
    (recipient {to: principal, ustx: uint})
    (prior (response bool uint)))
  (match prior
    ok-result (let (
      (to (get to recipient))
      (ustx (get ustx recipient)))
      (try! (stx-transfer? ustx tx-sender to))
      (ok true))
    err-result (err err-result)))

(define-public (send-many (recipients (list 200 {to: principal, ustx: uint})))
  (fold send-maybe recipients (ok true)))
```

### Parent-Child Maps (Hierarchical Data)

Store hierarchical data with pagination support.

```clarity
(define-map Parents uint {name: (string-ascii 32), lastChildId: uint})
(define-map Children {parentId: uint, id: uint} uint)

(define-read-only (get-child (parentId uint) (childId uint))
  (map-get? Children {parentId: parentId, id: childId}))

(define-private (is-some? (x (optional uint)))
  (is-some x))

(define-read-only (get-children (parentId uint) (shift uint))
  (filter is-some?
    (list
      (get-child parentId (+ shift u1))
      (get-child parentId (+ shift u2))
      (get-child parentId (+ shift u3))
      ;; ... up to page size
    )))
```

### Whitelisting (Assets/Contracts)

Control which contracts/assets can interact.

```clarity
(define-map Allowed {contract: principal, type: uint} bool)

;; Check in function
(asserts! (default-to false (map-get? Allowed {contract: contract, type: type}))
          ERR_NOT_ALLOWED)

;; Batch update
(define-public (set-allowed-list (items (list 100 {token: principal, enabled: bool})))
  (ok (map set-iter items (ok true))))
```

Examples: [ccd002-treasury-v3](https://github.com/citycoins/protocol/blob/main/contracts/extensions/ccd002-treasury-v3.clar), [aibtc-agent-account](https://github.com/aibtcdev/aibtcdev-daos/blob/main/contracts/agent/aibtc-agent-account.clar)

### Trait Whitelisting

Only allow calls from trusted trait implementations.

```clarity
(define-map TrustedTraits principal bool)

;; In functions accepting traits
(asserts! (default-to false (map-get? TrustedTraits (contract-of t)))
          ERR_UNTRUSTED)
```

### Delayed Activation

Activate functionality after a Bitcoin block delay.

```clarity
(define-constant DELAY u21000) ;; ~146 days in BTC blocks
(define-data-var activation-block uint u0)

;; Set on deploy or init
(var-set activation-block (+ burn-block-height DELAY))
