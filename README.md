# ERC-20T2

### Deferred-Settlement Fungible Token Standard · Reference Implementation

[![ERC](https://img.shields.io/badge/ERC--1693-Draft-blue)](https://github.com/ethereum/ERCs/pull/1693)
[![CI](https://github.com/LevanIlashvili/erc-20t2/actions/workflows/test.yml/badge.svg)](https://github.com/LevanIlashvili/erc-20t2/actions/workflows/test.yml)
[![Tests](https://img.shields.io/badge/tests-44%2F44-brightgreen)](./test/ERC20T2.t.sol)
[![Solidity](https://img.shields.io/badge/solidity-%5E0.8.20-lightgrey)](./src/ERC20T2.sol)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)

An extension of ERC-20 in which token transfers do not settle atomically and require affirmative consent from both counterparties.

Every `transfer` enters a **two-day settlement window**. The sender may `cancel` during the window. The recipient must explicitly `acknowledge` after the window closes; unacknowledged transfers are `reject`able by the recipient at any time and automatically reclaimable by the sender after a further five days (**T+7**).

---

## The Pitch

Between 2020 and 2026, the DeFi ecosystem lost more than **US\$12 billion** to exploits. Nearly all of them shared one structural feature: the transaction settled in the same block, and by the time anyone noticed, recovery was impossible.

Meanwhile, the NSCC has processed equities trades in the multi-trillion-dollar range every year for over a decade under a T+2 convention, without a comparable loss event.

ERC-20T2 brings deferred settlement to on-chain token transfers. Cancellation, rejection, and reclamation are all first-class operations. `balanceOf` returns **only** tokens that are actually yours to spend.

This is not a joke.

---

## Lifecycle

```
                                    T+0
                                     │
                                     ▼
                          ┌──────────────────────┐
                          │   sender.transfer    │
                          │  debit → in-flight   │
                          │  emit Initiated      │
                          └──────────┬───────────┘
                                     │
               T+0 ──────────────── T+2 ──────────────── T+7
                │                    │                    │
      ┌─────────┴────────┐           │          ┌─────────┴─────────┐
      │  sender.cancel   │           │          │  anyone.reclaim   │
      │  sender restored │           │          │  sender restored  │
      └──────────────────┘           │          └───────────────────┘
                                     │
                                     ▼
                        ┌──────────────────────────┐
                        │ recipient.acknowledge    │
                        │ credit recipient         │
                        │ emit Transfer (ERC-20)   │
                        └──────────────────────────┘

            recipient.reject  — callable at any time before terminal
                               — sender restored

```

Four terminal outcomes (`Settled`, `Cancelled`, `Rejected`, `Reclaimed`), each of which clears the pending entry. At **no point** in this lifecycle is there an interval during which the tokens are controlled by a single unilateral party. This is intentional.

---

## Quick Start

Requires [Foundry](https://getfoundry.sh).

```bash
git clone --recursive https://github.com/LevanIlashvili/erc-20t2
cd erc-20t2
forge test
```

Expected:

```
Suite result: ok. 44 passed; 0 failed; 0 skipped
```

## Live on Sepolia

A verified demo deployment is live for kicking the tires:

- **Contract:** [`0x3d8C0620eF32b8c554B37D25C510cb0c6C5F8aD7`](https://sepolia.etherscan.io/address/0x3d8C0620eF32b8c554B37D25C510cb0c6C5F8aD7)
- **Token:** `T2DEMO` — public `mint(address,uint256)` so anyone can mint themselves some and exercise the lifecycle
- **Source verified** on Sepolia Etherscan (all functions callable directly from the "Write Contract" tab)

Try it: mint yourself some, `transfer` to another address you control, watch `pendingTransferOf` for 48 hours, then call `acknowledge`. Or `cancel` inside the window. Or `reject`. Or wait 7 days and `reclaim`.

---

## Architecture

```
src/
├── IERC20T2.sol     — interface (11 functions + 5 events)
├── ERC20T2.sol      — abstract implementation of the full lifecycle
└── TestToken.sol    — concrete token with public mint/burn (tests only)

test/
└── ERC20T2.t.sol    — 44 tests
```

### Key departures from ERC-20

| Function              | ERC-20 behaviour                          | ERC-20T2 behaviour                                                              |
|-----------------------|-------------------------------------------|---------------------------------------------------------------------------------|
| `balanceOf`           | Returns total balance                     | Returns **available** balance only; pending transfers do not count              |
| `transfer`            | Atomic; emits `Transfer` immediately      | Enters pending state; emits `TransferInitiated`; `Transfer` emits on `acknowledge` |
| `transferFrom`        | Atomic; debits allowance                  | Pending state; debits allowance **at initiation**, and the debit is irreversible |
| `acknowledge` *(new)* | —                                         | Recipient finalises the transfer between T+2 and T+7                            |
| `cancel`      *(new)* | —                                         | Sender unwinds before T+2                                                       |
| `reject`      *(new)* | —                                         | Recipient returns funds to sender at any time before terminal                   |
| `reclaim`     *(new)* | —                                         | **Anyone** returns funds to sender after T+7                                    |

### Three new balance views

- `availableBalanceOf(account)` — what you can spend right now
- `pendingBalanceOf(account)` — what you may yet receive
- `inFlightBalanceOf(account)` — what you've sent but is not yet final

### Trade IDs

Each pending transfer is identified by a deterministic `tradeId`:

```solidity
tradeId = keccak256(abi.encode(from, to, amount, block.timestamp, nonce));
```

where `nonce` is a monotonically-increasing per-sender counter. This guarantees uniqueness and precludes a griefing vector in which an attacker repeats a previous `tradeId`.

---

## What It Breaks

A non-exhaustive list of things that do not work with ERC-20T2 tokens:

- **Flash loans.** A flash loan over a T+2 asset that also requires recipient acknowledgment is not a flash loan.
- **Silent-receipt integrations.** Any contract that expects its balance to be updated when tokens arrive. Receivers must call `acknowledge`, or the tokens get reclaimed after T+7.
- **Market-making strategies that assume immediate settlement of fills.** Orders now have a two-day fulfilment lifecycle.
- **"Send-and-forget" custodial patterns.** If the destination cannot acknowledge, the transfer does not complete.

The authors consider these breakages a feature, on the grounds that the resulting system more closely resembles the one that currently moves global capital without losing it.

---

## Security Model

The central invariant:

> At no point in the lifecycle is there an interval during which the tokens are controlled by a single unilateral party.

Between initiation and terminal state, tokens are held by the contract itself. There is no code path that permits an in-flight balance to be spent, burned, forwarded, or otherwise consumed without first passing through `acknowledge` / `cancel` / `reject` / `reclaim`.

The acknowledgment requirement does **not** create new attack surface. It **exposes** attack surface that already existed under ERC-20 (a compromised recipient key), while providing a 48-to-168-hour window during which unauthorised inbound transactions are visible and reversible. That is 48-to-168 hours more than ERC-20 provides.

Full discussion: [`erc-1693.md` §Security Considerations](./erc-1693.md#security-considerations).

---

## ERC Status

| Field              | Value                                                                 |
|--------------------|-----------------------------------------------------------------------|
| ERC number         | **1693**                                                              |
| Status             | Draft                                                                 |
| Category           | ERC                                                                   |
| Pull Request       | [ethereum/ERCs#1693](https://github.com/ethereum/ERCs/pull/1693)      |
| Tests              | 44 / 44 passing                                                       |

---

## FAQ

**Is this a serious proposal?**
The code is serious. Whether the proposal is serious is a question about financial risk, not about code.

**Does `balanceOf` really not count pending transfers?**
Yes. Pending tokens are in custody of the contract; crediting them to the recipient before the sender's cancellation window closes would permit double-spending and defeat the purpose of the standard.

**What happens if a recipient never calls `acknowledge`?**
After T+7, anyone can call `reclaim` to return the funds to the sender. Recipients who cannot acknowledge within a seven-day window have operational issues that sending them additional tokens will not resolve.

**Is there an opt-out?**
No. An opt-out would be indistinguishable from an attacker's signature under a compromised key, and would reintroduce the failure mode the standard exists to eliminate.

**Why doesn't `cancel` restore the allowance?**
Because a hostile sender could otherwise initiate-then-cancel in a loop, burning a spender's gas indefinitely at no cost. Allowances, once consumed, stay consumed. Senders who wish to re-authorise a cancelled spender should call `increaseAllowance` explicitly.

**Has this been audited?**
No. This is a reference implementation accompanying a **draft** EIP. Do not deploy it to mainnet.

**Can I wrap it into a regular ERC-20 for legacy DeFi?**
A wrapper is straightforward but out of scope. Any such wrapper is necessarily custodial over the underlying T+2 asset and therefore inherits **none** of the settlement-risk protection this standard provides.

**Will there be extensions?**
A companion standard (tentatively ERC-20T2B) is anticipated to introduce holiday-calendar awareness for tokens representing assets whose underlying markets are closed on weekends.

---

## Links

- **ERC PR:** https://github.com/ethereum/ERCs/pull/1693
- **Discussion:** https://ethereum-magicians.org/t/erc-1693-deferred-settlement-fungible-tokens/28295
- **Spec (in-repo):** [`erc-1693.md`](./erc-1693.md)
- **Interface:** [`src/IERC20T2.sol`](./src/IERC20T2.sol)
- **Implementation:** [`src/ERC20T2.sol`](./src/ERC20T2.sol)
- **Test suite:** [`test/ERC20T2.t.sol`](./test/ERC20T2.t.sol)

---

## License

Source code (`src/`, `test/`) — MIT.
ERC text (`erc-1693.md`) — CC0.

---

> *"We note without further comment that this argument is structurally identical to the one underpinning ACH's five-day return window, SWIFT's recall mechanisms, and every other production-grade payment system that has been operating successfully since before the invention of the blockchain."*
>
> — ERC-1693, §Motivation
