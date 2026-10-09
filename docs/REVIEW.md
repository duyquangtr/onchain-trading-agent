# Independent review of SPEC.md v1 (onchain-trading-agent, then called "Leash")

*Reviewer: independent staff-engineer pass (smart-contract security and LLM agents). I did not write the spec. Reviewed 2026-10-09. Factual checks were made live that day; see "Sources" at the end.*

## Verdict: **Fix, then ship**

The core idea is right: the AI proposes and the contract enforces, ticks are short and stateless, testnets only, and the stack choices fit a beginner. But two of the free-tier assumptions break at the planned volume (Gemini and GitHub Actions), and the parts the spec says are "designed up front" (caps, adapter trust, `reasonHash`) aren't specified yet. Right now each one could be built three different ways, and two of those ways are unsafe. The milestone order also contradicts the plan's own "walking skeleton" principle, because nothing goes live until M6. None of this needs a rework. It needs about a page of precise interface decisions and a reordering. Those changes are applied in SPEC.md v1.1. The exact signatures, events, record format, and SQL were moved into a new companion file, `INTERFACES.md`, so the spec stays readable.

---

## Must-fix (applied in v1.1)

**MF1. Gemini free tier can't serve ~72 calls a day on a Flash model.**
AI Studio currently lists the free tier at about **20 requests/day for Flash models** and **500/day for Flash-Lite** models. Quotas are per project and reset at midnight Pacific (3 am ET). A `*/20` cron makes 72 calls a day before counting retries or evals, so the agent would start getting HTTP 429 errors and turn every tick after about 7 am into a HOLD.
*Fix:* default to a **Flash-Lite** model with its model ID pinned in config. Only call the model when inputs changed (new headline, or a price move above a threshold); otherwise log a HOLD with reason "no new information". Run real-model evals only by manual dispatch, never on every PR. Budget at most 150 calls/day and check live limits in AI Studio.

**MF2. GitHub Actions cron on a private repo exceeds the free minutes, and branch protection isn't available there.**
Private repos on GitHub Free get 2,000 min/month, billed per job and rounded **up** to the whole minute. 72 runs/day × 30 days = 2,160 billed minutes at an absolute minimum, and realistically 3,000–4,000 once Python setup runs, before any CI. Protected branches and rulesets also only exist for **public** repos on Free, yet M3 requires branch protection. Separately, `*/20 * * * *` fires at minute 0, which contradicts the spec's own "avoid minute 0". GitHub says the top of the hour is when scheduled runs get delayed or dropped.
*Fix:* make the project repo **public**. That gives unlimited standard-runner minutes and branch protection, and it's a portfolio piece anyway. Secrets stay in Actions secrets. Use cron `7,27,47 * * * *`, `concurrency: {group: tick, cancel-in-progress: false}`, and `timeout-minutes: 5`. Note that public repos auto-disable schedules after 60 days without activity. If the user wants it private, tick every 30 min and skip branch protection. This is recorded as an Open Decision.
*Resolved (2026-10-09):* **public engine plus private strategy.** The engine repo `duyquangtr/onchain-trading-agent` is public; the strategy lives in the private `duyquangtr/onchain-trading-agent-strategy` and is loaded at run time (SPEC.md section 2c).

**MF3. The daily-cap semantics are undefined, so the fuzz test's promise is ambiguous.**
"Max spend per 24h, per token" doesn't say whether the window is rolling or a calendar day, or what units the cap is in. A rolling 24h window needs a history buffer. A calendar-day window allows up to 2× the cap across midnight. "No sequence of swaps exceeds the daily cap" is true for one model and false for the other. Pricing the cap in USD would need an oracle inside the vault, which is more trust and more code.
*Fix:* caps are **per `tokenIn`, in that token's base units** (mUSDC has 6 decimals, mWETH 18), in a `TokenLimits {allowed, maxPerTrade, maxPerDay}` struct. The window is a **UTC-day bucket**, `day = block.timestamp / 1 days`, and the spent counter resets when the day changes. Document the known worst case: up to 2× `maxPerDay` across 00:00 UTC (8 pm ET in summer). The invariant test then states it exactly: "for every token and every UTC day, the sum of `amountIn` ≤ `maxPerDay`".

**MF4. "Swap output always returns to the vault" is claimed but never designed.**
The spec doesn't say how tokens reach the adapter or how the vault confirms it got paid. A buggy or hostile adapter, or an agent-supplied `recipient`, could keep the funds.
*Fix:* freeze an `ISwapAdapter.swapExactIn(tokenIn, tokenOut, amountIn, minAmountOut)` with **no recipient and no free-form `bytes` argument**. The vault transfers exactly `amountIn` to the adapter, which has no lingering approvals. The vault then **measures its own balances before and after** and requires `tokenOut` received ≥ `minAmountOut` and `tokenIn` spent == `amountIn`. Otherwise the whole transaction reverts. Add `nonReentrant` and checks-effects-interactions: update `spentToday` and `lastTradeAt` before the external call. Also check `tokenIn != tokenOut`, both allowlisted, `amountIn > 0`, `minAmountOut > 0`, and a `deadline`. Add a test with a malicious `MockDEX` that keeps the tokens, which must revert.

**MF5. The worst case for a leaked agent key is understated.**
`minAmountOut` is chosen by the agent, so a stolen agent key can pass `minAmountOut = 1`. On a real AMM it can then sandwich its own trades and lose close to **100% of each day's cap**, every day until paused. "Bad trades within the daily limit" sounds milder than that. On the oracle-priced PaperDEX, the loss per trade is only the 0.3% fee.
*Fix:* state the honest bound in the Safety section: a leaked agent key can lose up to `maxPerDay` of each token per UTC day. Keep caps small relative to the vault, which is why there's a cooldown and a pause. For the Uniswap milestone, add an **on-chain price floor** as a should-fix: the vault or adapter checks `minAmountOut ≥ oraclePrice × (1 − maxSlippageBps)`. This also makes a strong explain-back question.

**MF6. `reasonHash` is circular and has no canonical form.**
Step 5 hashes a record that includes `tx hash` and `gas used`, but the hash is an *argument* to that same transaction. JSON key order, whitespace, and floats also serialize differently in Python and TypeScript, so the dashboard's "verify" button would fail on valid rows. Postgres `JSONB` also re-orders keys and drops whitespace.
*Fix:* hash only the **pre-transaction decision record**. Serialize it with `json.dumps(sort_keys=True, separators=(",",":"), ensure_ascii=False)` in UTF-8, with **no floats anywhere**: amounts and prices are decimal strings, confidence is an int from 0 to 100, times are UTC ISO-8601 with `Z`, and addresses are lowercase. `reasonHash = keccak256(bytes)`. Store those **exact bytes** in a `TEXT` column, never JSONB. Verify by keccak-hashing the stored text, with no re-serialization in TypeScript. Execution facts like `tx_hash`, gas, and status live in separate, un-hashed columns. v1.1 includes the exact schema.

**MF7. PaperDEX can be drained, and oracle reads are unchecked.**
If `mUSDC` has a public `mint` (most test tokens do) and PaperDEX trades with anyone at the oracle price, anyone can mint mUSDC and take all of PaperDEX's WETH. Reading Chainlink without staleness and decimals checks (the feed uses 8 decimals, tokens use 6 or 18) gives wrong prices without any error. The "keeper key" fallback is unnecessary, because the Chainlink ETH/USD feed on Base Sepolia exists and is live. I read it on-chain: `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`, "ETH / USD", 8 decimals, updated about 2 minutes before my call.
*Fix:* PaperDEX accepts swaps **only from allowlisted vaults**. Test tokens are `mUSDC` and **`mWETH`**, both owner-mint-only, so PaperDEX liquidity doesn't depend on faucet ETH. Require `answer > 0` and `block.timestamp − updatedAt ≤ maxStaleness`, which is configurable and defaults to 24h on testnet. Add a unit test for the decimal conversion. Drop the keeper fallback from v1.

**MF8. Idempotency, overlap, and nonces are missing.**
Scheduled runs can be late, dropped, re-run by hand, or overlap with a slow previous run. A run can also die after sending a transaction but before writing it to the DB.
*Fix:* (a) a workflow `concurrency` group. (b) `tick_id` set to the scheduled 20-minute slot in UTC, with a `PRIMARY KEY (chain_id, tick_id)`. Insert with `ON CONFLICT DO NOTHING` *before* sending; if no row was inserted, exit. (c) Before sending, require `getTransactionCount(pending) == getTransactionCount(latest)`; if a transaction is stuck, log `SKIP: pending tx` and send nothing. (d) Sign first, save `tx_hash` and nonce, then broadcast. The next tick can then repair any half-finished row by looking up the receipt by hash, without scanning events (see MF9). (e) The on-chain cooldown is the final backstop.

**MF9. The dashboard plans to read history from contract events, which free RPC can't serve.**
Alchemy's free tier caps `eth_getLogs` at a **10-block range**, which is about 20 seconds on Base. Scanning a week of history would take tens of thousands of calls. It works on anvil in M2 and then breaks at deploy.
*Fix:* the dashboard reads **history from Postgres**. It uses the chain only for live state (`balanceOf`, `remainingToday`, `paused`), for receipts by tx hash in "verify", and for owner write actions.

**MF10. The milestone order contradicts the walking-skeleton principle.**
The plan says to find real problems (keys, gas, cron, nonces) early, but nothing touches a real network until M6, after the AI brain and the Uniswap work.
*Fix:* reorder. M4 ships the **dumb-rule agent live on Base Sepolia**, with PaperDEX, cron, Neon, and Vercel. The brain comes after (M5), then Uniswap fork testing (M6). The decision record and `reasonHash` move into M2, so the hard-to-change interface gets used from day one.

---

## Should-fix (applied in v1.1 where clear)

- **SF1. M1 is too big for a first Solidity milestone.** It covers roles, deposits, withdrawals, pause, allowlists, two caps, cooldown, swap, an adapter, events, fuzzing, and 90% coverage. Split it into **M1a** (roles, deposit, withdraw, pause, limits config, events, unit tests) and **M1b** (swap through MockDEX, caps, cooldown, balance-delta check, malicious-adapter test, invariant test). *Applied.*
- **SF2. The M1 explain-back question doesn't fit this contract.** "Why does `withdraw` set the balance before sending" comes from savings-pot, which had per-user balances. The vault has one owner and no balance to zero. Replace it with "Why do we update `spentToday` before calling the adapter, and why does the vault count its own balance instead of trusting the adapter's return value?" *Applied.*
- **SF3. Interfaces and events are under-specified.** There are no events for config changes, but the dashboard and audits need them. Add `TokenLimitsSet`, `AdapterSet`, `AgentSet`, `CooldownSet`, OpenZeppelin `Pausable`'s `Paused`/`Unpaused`, `Ownable2Step` to prevent owner-transfer typos, and a `remainingToday(token)` view. Let the **agent also call `pause()`** (never `unpause`) so it can trip its own circuit breaker. *Applied (frozen interface section).*
- **SF4. The LLM should never pick raw amounts or addresses.** Output `{action, asset: "ETH", size_pct: 0–100 of maxPerTrade, confidence: 0–100, reasoning, sources_used: [idx]}`, and have Python convert that to base units and addresses. Models are bad at decimals, and this also shrinks the prompt-injection surface. *Applied.*
- **SF5. Drop the off-chain "mirror the contract's rules" pre-check.** Duplicated rule logic drifts out of sync. Read `remainingToday` and simulate with `eth_call`, which runs the real contract. *Applied.*
- **SF6. `make dev` won't run on Windows Git Bash,** which is where the user works, because `make` isn't installed. Use a root `npm run dev` (with `concurrently`), the same pattern as Genesis. *Applied.*
- **SF7. Using SQLite locally and Postgres in prod means two SQL dialects.** Use Postgres everywhere: a Neon `dev` branch locally and a `postgres` service container in CI. *Applied.*
- **SF8. Secret scanning and `.gitignore` start in M3, but `.env` files appear in M2.** Add gitleaks, `.gitignore`, and a minimal `forge test` CI in M1a. *Applied.*
- **SF9. Gas, faucet, and key hygiene are missing.** The CDP faucet gives 0.1 Base Sepolia ETH per address per day. Alchemy's faucet needs 0.001 ETH on Ethereum mainnet. The agent should log its ETH balance each tick and alert below 0.002 ETH. HOLD ticks cost no gas. The user's MetaMask already contains the imported **public Anvil key** ("Anvil TEST"), which must never be the owner, deployer, or agent on Base Sepolia. Use a fresh account. *Applied.*
- **SF10. Time zones aren't stated.** The contract uses UTC days, cron runs in UTC, Gemini quotas reset at midnight PT, and the dashboard should show ET. *Applied.*
- **SF11. Real-model red-team evals run on every PR.** That burns quota, and repo secrets aren't passed to workflows triggered from fork PRs. Run them by manual dispatch, plus nightly at most. Cut the set to about 8 scenarios for v1. *Applied.*
- **SF12. HOLD records aren't anchored on-chain,** so they could be deleted silently. Add `prev_record_hash` to the record to form a hash chain. Each on-chain trade then also vouches for every HOLD before it, at zero extra cost. It's cheap now and hard to add later. *Applied.*
- **SF13. Uniswap adapter details.** Use **SwapRouter02** `exactInputSingle`. Its params struct has no `deadline`, so wrap the call in `multicall(deadline, data)` or rely on the vault's `deadline`. Set the fee tier per pair in owner config, not by the agent. Pin the fork block number so tests are reproducible. *Applied.*
- **SF14. Keep the CoinGecko Demo budget in view.** 10k calls/month at 72 ticks/day leaves at most 4 calls per tick. Cache results, and include attribution, which the Demo plan requires. *Applied (one line).*
- **SF15. A vault that accepts native ETH needs `receive()` and wrap logic.** Make the vault ERC-20 only (`mWETH`/`mUSDC`, or real WETH on the fork). *Applied.*

## Nice-to-have (not applied)

- Use `uv` to manage Python on Windows, which makes the venv and lockfile painless.
- Expose `getLimits()`/`status()` views that return everything the dashboard needs in one call.
- Post a daily Merkle root of all records on-chain. The hash chain (SF12) covers most of the value for free.
- Show a "how much could a stolen agent key lose today?" number on the dashboard, computed from the caps.
- Add Slither to CI once the vault is stable (M3+).
- The chain switcher in M8 can be per-chain routes (`/base-sepolia`, `/arbitrum-sepolia`) rather than a dynamic switcher.

## Over-engineering cut from v1

- The keeper-key price fallback, since the Chainlink feed exists.
- The off-chain mirror of contract rules (SF5).
- Real-model evals in CI on every PR (SF11).
- Ethereum Sepolia deploy, which was already optional. Kept optional.
- The 15-scenario eval set, cut to about 8 for v1.

## Things the spec got right (verified)

- The GitHub Actions schedule minimum is 5 min, and runs can be delayed or dropped under load ✔.
- Uniswap v3 is deployed on Base Sepolia ✔. Factory is `0x4752…aD24` and SwapRouter02 is `0x94cC…12bc4`. I confirmed bytecode exists on-chain at both addresses on 2026-10-09.
- Chainlink ETH/USD exists on Base Sepolia ✔ (see MF7).
- Free-tier Gemini prompts may be used to improve Google's products ✔, and no card is needed ✔.
- Neon Free gives 100 CU-hours per project per month and scales to zero after 5 minutes ✔. 72 short wake-ups a day uses roughly 45 CU-hours a month at 0.25 CU, which fits. Expect a cold start of about 1 second.
- CoinGecko Demo gives 10k calls/month at 100/min ✔.
- Not re-verified: the CDP Swap/policy mainnet-only claims and the Alchemy 30M CU figure. Neither changes the design.

## Sources (checked 2026-10-09)

- Gemini rate limits (per project, RPD resets at midnight PT; live limits in AI Studio): https://ai.google.dev/gemini-api/docs/rate-limits
- Free-tier RPD by model (Flash ~20, Flash-Lite 500, as reported from AI Studio, Sept 2026): https://www.scriptbyai.com/gemini-api-free-tier-limits/ ; forum confirmation of the 20 RPD Flash cut: https://discuss.ai.google.dev/t/is-gemini-2-5-pro-disabled-for-free-tier/111261/44
- Gemini pricing ("used to improve our products: yes" on free): https://ai.google.dev/gemini-api/docs/pricing
- GitHub `schedule` (5-min minimum, delays and drops at the top of the hour, 60-day auto-disable in public repos): https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows
- GitHub Actions billing (free for public repos; 2,000 min for private on Free; rounded up per job): https://docs.github.com/en/billing/concepts/product-billing/github-actions and https://github.com/github/docs/blob/main/content/actions/how-tos/monitor-workflows/view-job-execution-time.md
- Protected branches only on public repos for GitHub Free: https://docs.github.com/en/rest/branches/branch-protection
- Uniswap v3 Base Sepolia addresses: https://developers.uniswap.org/docs/protocols/v3/deployments/v3-base-deployments (bytecode checked via `eth_getCode` on https://sepolia.base.org)
- SwapRouter02 has no deadline in `ExactInputSingleParams`; use `multicall(deadline, …)`: https://github.com/Uniswap/swap-router-contracts/blob/main/contracts/base/MulticallExtended.sol
- Chainlink ETH/USD on Base Sepolia `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`: `description()`, `decimals()`, and `latestRoundData()` read via `eth_call` on https://sepolia.base.org (answer ≈ $2,484, updated 09:54 ET). Feed directory: https://docs.chain.link/data-feeds/price-feeds/addresses
- Alchemy free-tier `eth_getLogs` 10-block range: https://www.alchemy.com/docs/chains/ethereum/ethereum-api-endpoints/eth-get-logs and https://support.alchemy.com/articles/1883074130-why-do-i-see-a-free-tier-error-when-calling-eth-getlogs-with-a-large-block-range
- Base Sepolia faucets (CDP 0.1 ETH per 24h; Alchemy needs 0.001 mainnet ETH): https://docs.cdp.coinbase.com/faucets/introduction/welcome , https://www.alchemy.com/faucets/base-sepolia , https://docs.base.org/base-chain/network-information/network-faucets
- Neon Free limits: https://neon.com/faqs/free-plan-limits-and-quotas
- CoinGecko Demo (10k/month, 100/min, attribution): https://www.coingecko.com/en/api/pricing
