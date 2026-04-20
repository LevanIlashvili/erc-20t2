# ERC-1693: Deferred-Settlement Fungible Tokens

Opening a discussion thread for **ERC-1693**, a proposed extension to ERC-20 introducing a T+2 settlement period and affirmative bilateral consent between counterparties.

- **PR:** https://github.com/ethereum/ERCs/pull/1693
- **Reference implementation:** https://github.com/LevanIlashvili/erc-20t2 (Solidity + 44 Foundry tests, MIT)

## Summary

Under ERC-20, `transfer` settles atomically and irrevocably. Between 2020 and 2026, the DeFi ecosystem has lost in excess of **US$12 billion** to exploits whose shared structural feature is same-block settlement: by the time any party becomes aware of an unauthorised transaction, recovery is impossible.

ERC-1693 introduces a lifecycle in which every transfer enters a two-day settlement window (T+2), during which the sender may `cancel` and the recipient may `reject`. Finalisation after T+2 requires the recipient to explicitly `acknowledge`; unacknowledged transfers are automatically reclaimable by the sender after a further five days (T+7).

At no point in this lifecycle is there an interval during which the tokens are controlled by a single unilateral party. This is intentional.

## Motivation

The design draws directly on the bilateral-consent, deferred-settlement conventions of NSCC T+2 equities clearing and ACH's five-business-day return window — systems which have processed settlement in the multi-trillion-dollar range per annum for decades without the class of losses that has become routine in DeFi.

A key point elaborated in the spec: sender-side cancellation **alone** is insufficient. It protects senders against their own erroneous transfers, but offers no protection in the case that concerns this proposal most — compromise of a sender's private key. In that scenario, the only party empowered to cancel is the compromised party. Bilateral consent — requiring the **recipient** to affirmatively accept each incoming transfer — closes this gap.

## Questions I'd welcome feedback on

1. Is the T+2 window correct, or should the standard parameterise the settlement period with a per-token bound (floor of 172800s, implementations MAY lengthen)?
2. Is `balanceOf` returning `availableBalanceOf` (and **not** `pending`) the right semantic? The spec argues yes on double-spend grounds; integrators may disagree.
3. Allowance non-restoration on `cancel` / `reject` / `reclaim`: the spec argues this is necessary to prevent a hostile-sender grief loop. Alternative designs welcome.
4. Does recipient-acknowledgment eliminate too many legitimate "send-and-forget" patterns, or is that precisely the point?

## What it breaks (a non-exhaustive list)

- Flash loans over ERC-1693 assets. A flash loan that requires recipient acknowledgment is not a flash loan.
- Silent-receipt integrations: contracts that expect their balance to update on inbound `transfer` without calling `acknowledge` will have those transfers reclaimed at T+7.
- Market-making strategies assuming immediate settlement of fills.
- "Send and forget" custodial patterns.

The spec argues these breakages are a feature, not a deficiency.

## Closing

Full specification and reference implementation in the PR. The reference implementation exercises all four terminal outcomes (`Settled` / `Cancelled` / `Rejected` / `Reclaimed`), every time-window boundary, and the allowance invariants.

Happy to iterate on any of the above.
