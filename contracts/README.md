# contracts — AgentVault (Foundry)

The on-chain "leash" for the trading agent. This folder holds the Solidity
contracts and their Foundry tests. **Milestone M1a** ships the vault's
foundation: owner/agent roles, deposits, withdrawals, the pause switch, and the
config setters. Trading (`swap`) and the per-trade / per-day caps arrive in M1b.

> Testnets only. Never put a real private key, mnemonic, or API key in this repo.

## Prerequisites

- [Foundry](https://getfoundry.sh) **1.8.5** (`forge`, `cast`, `anvil`). Check with `forge --version`.
- Git, to pull the pinned dependencies (installed as submodules).

Pinned versions (so everyone builds the same bytecode):

| Thing | Version |
|---|---|
| Solidity compiler (`solc`) | 0.8.28 (set in `foundry.toml`) |
| `forge-std` | v1.9.7 (git submodule) |
| OpenZeppelin Contracts | v5.1.0 (git submodule) |

## Running the tests (Git Bash on Windows)

All commands are plain `forge` / `git` — no `make`, no `/tmp`, no Linux-only
tools — so they work the same in Git Bash on Windows, macOS, and Linux.

```bash
# 1. From the repo root, get the pinned dependencies the first time:
git submodule update --init --recursive

# 2. Move into this folder:
cd contracts

# 3. Build and test:
forge build
forge test            # add -vvv to see traces for a failing test

# 4. See how much of the vault the tests exercise:
forge coverage --no-match-coverage "test/|lib/"
```

## What each function does (one line each)

Owner funding (owner only; both still work while the vault is paused):

- `deposit(token, amount)` — pull `amount` of `token` from the owner into the vault.
- `withdraw(token, amount, to)` — send `amount` of `token` from the vault to `to`.

Owner settings (owner only):

- `setTokenLimits(token, limits)` — store the allow flag and per-trade / per-day caps for one input token.
- `setAdapter(adapter, allowed)` — allow or disallow an exchange adapter the agent may route through.
- `setAgent(newAgent)` — change the trading key; `address(0)` disables trading entirely.
- `setCooldown(secs)` — set the minimum seconds between trades (enforced by `swap` in M1b).

Ownership (two-step, from OpenZeppelin `Ownable2Step`):

- `transferOwnership(newOwner)` — propose a new owner (nothing changes until they accept).
- `acceptOwnership()` — the proposed owner accepts and takes over.

Pause switch:

- `pause()` — stop all trading immediately; callable by **owner or agent**.
- `unpause()` — resume trading; **owner only**, so a compromised agent can't re-enable itself.

Views:

- `owner()` / `pendingOwner()` — current owner and the pending one during a transfer.
- `agent()` — the current trading address.
- `cooldown()` — the global cooldown in seconds.
- `tokenLimits(token)` — the stored `TokenLimits { allowed, maxPerTrade, maxPerDay }`.
- `allowedAdapters(adapter)` — whether an adapter is allowlisted.
- `paused()` — whether trading is currently paused.

## Why the agent can pause but not unpause

The agent is the AI's key. If it ever misbehaves or leaks, we want it to be able
to slam the brakes (`pause`) but never to release them (`unpause`) — only the
human owner can do that. And `withdraw` keeps working while paused, so the owner
can always rescue the funds no matter what state the agent left things in.
