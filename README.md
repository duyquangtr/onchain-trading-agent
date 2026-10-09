# onchain-trading-agent

An autonomous AI trading agent with on-chain guardrails. Every 20 minutes it reads crypto news and prices, decides whether to buy, sell, or hold, explains why, and trades through a vault contract its owner controls. Every decision is logged, and each trade carries a hash of its reasoning on-chain, so explanations can't be edited after the fact.

**Testnets only (Base Sepolia, Arbitrum Sepolia, Sepolia, local anvil). No real money, ever.**

## Safety model in 3 lines

1. **The AI proposes, the contract disposes.** Funds sit in an `AgentVault` contract, not in the AI's wallet.
2. The vault enforces per-trade and per-day caps, an allowlist of tokens and exchanges, a cooldown, and checks its own balance after every swap.
3. The owner can pause instantly and withdraw at any time, even while paused; the agent can pause itself but never unpause or withdraw.

## How it's organized

This public repo is the **engine**: contracts, the tick pipeline, tests, CI, the dashboard, and a plain sample strategy. The real trading strategy lives in a separate private repo and plugs in through a small `Strategy` interface. See [SPEC.md section 2c](SPEC.md#2c-two-repos-public-engine-private-strategy).

## Docs

- [SPEC.md](SPEC.md): product spec, system design, safety model, and the milestone plan
- [INTERFACES.md](INTERFACES.md): the frozen interfaces (vault functions, events, strategy interface, decision record, database table)
- [docs/REVIEW.md](docs/REVIEW.md): the independent design review behind spec v1.1
- [AGENTS.md](AGENTS.md): rules for anyone (human or AI) writing code here

## Status

Spec v1.2 is done; there's no code yet. **Next up: M1a, vault basics** (the `AgentVault` contract with roles, deposit, withdraw, and pause, plus Foundry tests).

## License

[MIT](LICENSE) © 2026 Stephen Tran
