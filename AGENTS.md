# Rules for coding agents (and humans)

Read [SPEC.md](SPEC.md) and [INTERFACES.md](INTERFACES.md) before changing anything.

## How work gets done
- **One milestone step per small PR.** Don't mix milestones or sneak in unrelated changes.
- **`forge test` and `pytest` must pass** before a PR is opened (run whichever apply to what changed, and say so in the PR).
- The interfaces in `INTERFACES.md` are frozen. Changing one needs its own reviewed PR that bumps the version.

## Safety
- **Testnets only:** Base Sepolia (84532), Arbitrum Sepolia (421614), Sepolia (11155111), local anvil (31337). Never add mainnet config, mainnet RPC URLs, or real funds.
- **Never commit secrets:** no private keys, no mnemonics, no API keys, no `.env` files, and no RPC URLs that contain a key. Only `.env.example` with placeholder names is allowed.
- Never use anvil's public test keys anywhere except a local anvil chain.

## Strategy stays private
- **Never put real strategy logic in this repo:** no prompts, signals, news weighting, tuned thresholds, or trading rules beyond the plain `sample-dip` sample.
- Strategies plug in only through the `Strategy` interface and `STRATEGY_DIR` (SPEC.md section 2c).
- Never print prompts, raw model output, or reasoning text to stdout or Actions logs; this repo's logs are public.

## Code style
- The owner is learning. Write **beginner-readable code**: clear names, small functions, and comments that explain *why*, not just what.
- Commands must work in **Git Bash on Windows**: no `make`, no `/tmp` paths, no Linux-only tools. Use `npm run ...` scripts and relative paths.
