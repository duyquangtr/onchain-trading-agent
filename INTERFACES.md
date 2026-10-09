# onchain-trading-agent: frozen interfaces (v1.2)

*Companion to SPEC.md sections 2b and 2c. These are the exact signatures, events, strategy interface, record format, and table that M1a–M2 implement. Changing any of them after deploy means a new contract or re-hashing old records, so change them only through a reviewed PR that bumps the version.*

These get designed up front because a deployed contract can't be edited and old log rows can't be re-hashed. Everything else (prompts, strategy, dashboard look) starts crude and improves.

**Vault rules, precisely.**
- Caps are **per input token, in that token's smallest units** (mUSDC has 6 decimals, mWETH 18). No USD pricing inside the vault in v1.
- The daily window is the **UTC day**: `day = block.timestamp / 1 days`. When the day changes, the spent counter resets. Known edge: up to 2× the daily cap can go out across midnight UTC (8 pm ET in summer). That's acceptable, and it's tested and written down.
- Cooldown is global: no trade within `cooldown` seconds of the last one.
- The vault holds ERC-20 tokens only (no native ETH). Owner transfer is two-step (OpenZeppelin `Ownable2Step`). The contract isn't upgradeable; to change it, deploy a new vault, withdraw, and re-fund.

```solidity
struct TokenLimits { bool allowed; uint128 maxPerTrade; uint128 maxPerDay; } // base units of that token

// agent only, whenNotPaused, nonReentrant
function swap(address adapter, address tokenIn, address tokenOut, uint256 amountIn,
              uint256 minAmountOut, uint256 deadline, bytes32 reasonHash) external returns (uint256 amountOut);
function remainingToday(address token) external view returns (uint256);
// owner only (all still work while paused)
function deposit(address token, uint256 amount) external;
function withdraw(address token, uint256 amount, address to) external;
function setTokenLimits(address token, TokenLimits calldata limits) external;
function setAdapter(address adapter, bool allowed) external;
function setAgent(address agent) external;      // address(0) = agent fully disabled
function setCooldown(uint32 secs) external;
function pause() external;    // owner OR agent (the agent may trip its own breaker)
function unpause() external;  // owner only

interface ISwapAdapter {
  // The vault has already sent exactly amountIn of tokenIn to the adapter.
  // The adapter must send all output to msg.sender. No recipient, no extra bytes.
  function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
      external returns (uint256 amountOut);
}
```

**What `swap` checks, in order:** caller is the agent, not paused, `block.timestamp <= deadline`; adapter, `tokenIn` and `tokenOut` allowlisted, `tokenIn != tokenOut`, `amountIn > 0`, `minAmountOut > 0`; `amountIn <= maxPerTrade`; roll the day, then `spent + amountIn <= maxPerDay`; cooldown passed. **Then update `spent` and `lastTradeAt` (before any outside call)**, record both balances, transfer `amountIn` to the adapter, call it, and **measure**: `tokenOut` received must be at least `minAmountOut`, and `tokenIn` spent must equal `amountIn` exactly. Otherwise the whole transaction reverts. The vault believes its own balance sheet, never the adapter's return value.

**Events.**
```solidity
event TradeExecuted(bytes32 indexed reasonHash, address indexed tokenIn, address indexed tokenOut,
                    address adapter, uint256 amountIn, uint256 amountOut, uint256 spentTodayIn);
event Deposited(address indexed token, address indexed from, uint256 amount);
event Withdrawn(address indexed token, address indexed to, uint256 amount);
event TokenLimitsSet(address indexed token, bool allowed, uint128 maxPerTrade, uint128 maxPerDay);
event AdapterSet(address indexed adapter, bool allowed);
event AgentSet(address indexed previousAgent, address indexed newAgent);
event CooldownSet(uint32 secs);
// Paused(address) and Unpaused(address) come from OpenZeppelin Pausable.
```

**What the model returns** (validated with Pydantic; Python turns it into amounts and addresses):
`{"action": "BUY"|"SELL"|"HOLD", "asset": "ETH", "size_pct": 0-100, "confidence": 0-100, "reasoning": "...", "sources_used": [0, 3]}`
`size_pct` is a percentage of `maxPerTrade`, and `sources_used` holds indexes into the headline list.

**The strategy interface (Python, in the public engine at `agent/strategy_api.py`).** This is the only thing the private strategy repo depends on. Changing it means updating both repos, so treat it like the contract: change it only through a reviewed PR that bumps the version.
```python
from typing import Literal, Protocol
from pydantic import BaseModel, Field

STRATEGY_API_VERSION = "1"

class Headline(BaseModel):
    index: int                  # what sources_used refers to
    source: str
    title: str
    url: str
    published_at: str           # UTC, ends in "Z"

class Snapshot(BaseModel):      # built by the engine; read-only for the strategy
    tick_id: str
    observed_at: str
    prices: dict[str, str]                  # e.g. {"ETH_USD": "2484.27"}; decimal strings, no floats
    price_history_24h: list[tuple[str, str]]  # (time, ETH_USD)
    headlines: list[Headline]
    vault_paused: bool
    remaining_today_pct: dict[str, int]     # per asset, 0-100 of maxPerDay left
    changed_since_last: bool                # False = no new headline and price moved < 0.5%

class Decision(BaseModel):      # same shape as "What the model returns", plus metadata
    action: Literal["BUY", "SELL", "HOLD"]
    asset: Literal["ETH"]
    size_pct: int = Field(ge=0, le=100)     # % of maxPerTrade; the engine turns it into amounts
    confidence: int = Field(ge=0, le=100)
    reasoning: str                          # goes into the private DB, never into public logs
    sources_used: list[int] = []
    prompt_version: str | None = None
    raw_output: str = ""                    # raw model text, if any

class Strategy(Protocol):
    name: str
    version: str
    def decide(self, snapshot: Snapshot) -> Decision: ...

# A strategy folder must contain strategy.py with:
#   def create_strategy(model: ModelClient) -> Strategy
# ModelClient is the engine's model wrapper (or FakeModel in tests); it enforces the daily call cap.
```
**Loading:** if `STRATEGY_DIR` is set, the engine imports `$STRATEGY_DIR/strategy.py` with `importlib` and calls `create_strategy(model)`. If it isn't set, it uses the built-in `sample-dip` strategy. Any exception or invalid `Decision` becomes HOLD with the error in `checks.notes`. The strategy gets no keys, no RPC, and no database access. Its `name` and `version` go into `brain.strategy` and `brain.strategy_version` of the decision record.

**The decision record and `reasonHash`.** One JSON object per tick, written *before* any transaction, so it never contains a tx hash:
```json
{"schema":"trading_agent.decision.v1","chain_id":84532,"vault":"0x…","tick_id":"2026-10-09T13:40Z",
 "observed_at":"2026-10-09T13:47:12Z","prev_record_hash":"0x…",
 "inputs":{"prices":{"ETH_USD":"2484.27"},"headlines":[{"source":"coindesk","title":"…","url":"…","published_at":"…"}],
           "vault":{"balances":{"0x…":"1000000000"},"remaining_today":{"0x…":"50000000"}}},
 "brain":{"kind":"rule|llm","strategy":"sample-dip","strategy_version":"1","model":"…","prompt_version":"v1","raw_output":"…"},
 "decision":{"action":"BUY","token_in":"0x…","token_out":"0x…","amount_in":"5000000","min_amount_out":"…",
             "size_pct":20,"confidence":72,"reasoning":"…","sources_used":[0,3]},
 "checks":{"schema_ok":true,"simulated_ok":true,"notes":[]}}
```
Rules: **no floats anywhere** (amounts and prices are decimal strings, scores are whole numbers), times are UTC with a `Z`, and addresses are lowercase. Serialize with `json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")`, and `reasonHash = keccak256(those bytes)`. Store **those exact bytes** in the database. To verify, hash the stored text again and compare it with the on-chain event; nothing gets re-serialized. `prev_record_hash` links every record, HOLDs included, to the one before it, so each on-chain trade also vouches for every HOLD before it.

**Database (Postgres everywhere: a Neon `dev` branch locally, a `postgres` container in CI, Neon `main` in prod).**
```sql
CREATE TABLE ticks (
  chain_id     INTEGER     NOT NULL,
  tick_id      TEXT        NOT NULL,          -- 20-min UTC slot; makes re-runs harmless
  started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  action       TEXT        NOT NULL,          -- BUY | SELL | HOLD | SKIP
  status       TEXT        NOT NULL,          -- decided | sent | confirmed | reverted | failed | skipped
  record_json  TEXT        NOT NULL,          -- exact hashed bytes; TEXT, never JSONB (JSONB reorders keys)
  reason_hash  TEXT        NOT NULL UNIQUE,
  tx_hash      TEXT        UNIQUE,
  nonce        BIGINT,
  gas_used     BIGINT,
  error        TEXT,
  PRIMARY KEY (chain_id, tick_id)
);
```
The agent inserts with `ON CONFLICT DO NOTHING`; if no row went in, another run already handled this slot, so it exits. The agent signs the swap transaction, saves `tx_hash` and `nonce` (status `sent`), and only then broadcasts. If a run dies, the next tick looks up the receipt by `tx_hash` and moves the row to `confirmed` or `reverted`; it never needs an event scan. The dashboard reads **history from this table**. Free RPC plans only let you scan about 10 blocks of events per call, about 20 seconds on Base, so the dashboard uses the chain only for live balances, receipts, and owner actions.
