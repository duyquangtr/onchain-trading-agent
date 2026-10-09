// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AgentVault (M1a foundation)
/// @notice A vault that holds ERC-20 tokens for an AI trading agent and keeps
///         the money on a short leash: the owner funds it and sets the rules,
///         while a separate "agent" address is the only one that may trade.
/// @dev This is milestone M1a: it ships the owner/agent roles, deposits,
///      withdrawals, the pause switch, and the config setters (token limits,
///      adapter allowlist, agent, cooldown) plus every event from
///      INTERFACES.md section 2b. The actual `swap()` and the per-trade /
///      per-day cap enforcement arrive in M1b, so the cap fields are stored
///      here but not yet read during a trade.
///
///      Why these choices:
///      - `Ownable2Step`: an owner transfer needs the new owner to accept, so a
///        single fat-fingered address can't lock the vault forever.
///      - `Pausable`: the agent can trip the brake (`pause`) if it sees trouble,
///        but only the owner can release it (`unpause`). Withdrawals still work
///        while paused, so the owner can always rescue funds.
///      - `SafeERC20`: some tokens don't return a bool; SafeERC20 handles them.
contract AgentVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------- //
    //                                Types                                  //
    // --------------------------------------------------------------------- //

    /// @notice Trading limits for one input token, in that token's base units.
    /// @dev Caps are per input token (mUSDC has 6 decimals, mWETH 18); there is
    ///      no USD pricing inside the vault. `maxPerTrade` and `maxPerDay` are
    ///      stored now and enforced by `swap()` in M1b.
    struct TokenLimits {
        bool allowed; // may this token be traded at all?
        uint128 maxPerTrade; // most that can leave in a single swap
        uint128 maxPerDay; // most that can leave within one UTC day
    }

    // --------------------------------------------------------------------- //
    //                                State                                  //
    // --------------------------------------------------------------------- //

    /// @notice The only address allowed to call `swap()` (set in M1b).
    /// @dev `address(0)` means the agent is fully disabled and cannot trade.
    address public agent;

    /// @notice Minimum number of seconds between two trades (global cooldown).
    uint32 public cooldown;

    /// @notice Per-token trading limits and allow flag.
    mapping(address token => TokenLimits limits) public tokenLimits;

    /// @notice Which exchange adapters the agent is allowed to route through.
    mapping(address adapter => bool allowed) public allowedAdapters;

    // --------------------------------------------------------------------- //
    //                                Events                                 //
    // --------------------------------------------------------------------- //
    // These match INTERFACES.md section 2b and are frozen. `TradeExecuted` is
    // declared here so the event ABI is fixed from day one; it is emitted by
    // `swap()` starting in M1b.

    event TradeExecuted(
        bytes32 indexed reasonHash,
        address indexed tokenIn,
        address indexed tokenOut,
        address adapter,
        uint256 amountIn,
        uint256 amountOut,
        uint256 spentTodayIn
    );
    event Deposited(address indexed token, address indexed from, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event TokenLimitsSet(address indexed token, bool allowed, uint128 maxPerTrade, uint128 maxPerDay);
    event AdapterSet(address indexed adapter, bool allowed);
    event AgentSet(address indexed previousAgent, address indexed newAgent);
    event CooldownSet(uint32 secs);
    // `Paused(address)` and `Unpaused(address)` come from OpenZeppelin Pausable.

    // --------------------------------------------------------------------- //
    //                                Errors                                 //
    // --------------------------------------------------------------------- //

    /// @notice Thrown when someone who is neither the owner nor the agent tries
    ///         to pause the vault.
    error NotOwnerOrAgent(address caller);

    /// @notice Thrown when an amount argument that must be non-zero is zero.
    error ZeroAmount();

    /// @notice Thrown when a recipient/token address that must be set is zero.
    error ZeroAddress();

    /// @notice Thrown when someone tries to renounce ownership (disabled here).
    error RenounceDisabled();

    // --------------------------------------------------------------------- //
    //                              Constructor                              //
    // --------------------------------------------------------------------- //

    /// @param initialOwner The account that funds the vault and sets the rules.
    /// @param initialAgent The trading key (may be `address(0)` to start disabled).
    constructor(address initialOwner, address initialAgent) Ownable(initialOwner) {
        // `_setAgent` emits AgentSet so the first agent is recorded on-chain too.
        _setAgent(initialAgent);
    }

    // --------------------------------------------------------------------- //
    //                               Modifiers                               //
    // --------------------------------------------------------------------- //

    /// @dev Lets either the owner or the agent through. Used only by `pause()`
    ///      so the agent can trip its own circuit breaker.
    modifier onlyOwnerOrAgent() {
        if (msg.sender != owner() && msg.sender != agent) {
            revert NotOwnerOrAgent(msg.sender);
        }
        _;
    }

    // --------------------------------------------------------------------- //
    //                           Owner: funding                              //
    // --------------------------------------------------------------------- //

    /// @notice Pull `amount` of `token` from the owner into the vault.
    /// @dev The owner must `approve` this vault on the token first. Works while
    ///      paused so the owner can always top up. `nonReentrant` is belt-and-
    ///      braces around the external token call.
    ///      We emit the amount the vault *actually received* (balance after
    ///      minus before), not the requested `amount`. For our own mUSDC/mWETH
    ///      these are equal, but a fee-on-transfer token would deliver less, and
    ///      the event should never overstate the balance.
    function deposit(address token, uint256 amount) external nonReentrant onlyOwner {
        if (amount == 0) revert ZeroAmount();
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        emit Deposited(token, msg.sender, received);
    }

    /// @notice Send `amount` of `token` from the vault to `to`.
    /// @dev Owner-only and intentionally still works while paused: pausing stops
    ///      trading, never the owner's ability to rescue funds.
    function withdraw(address token, uint256 amount, address to) external nonReentrant onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    // --------------------------------------------------------------------- //
    //                           Owner: settings                             //
    // --------------------------------------------------------------------- //

    /// @notice Set (or clear) the trading limits for one input token.
    function setTokenLimits(address token, TokenLimits calldata limits) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        tokenLimits[token] = limits;
        emit TokenLimitsSet(token, limits.allowed, limits.maxPerTrade, limits.maxPerDay);
    }

    /// @notice Allow or disallow an exchange adapter the agent may route through.
    function setAdapter(address adapter, bool allowed) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        allowedAdapters[adapter] = allowed;
        emit AdapterSet(adapter, allowed);
    }

    /// @notice Change the trading agent. `address(0)` disables trading entirely.
    function setAgent(address newAgent) external onlyOwner {
        _setAgent(newAgent);
    }

    /// @notice Set the global cooldown (seconds) enforced between trades in M1b.
    function setCooldown(uint32 secs) external onlyOwner {
        cooldown = secs;
        emit CooldownSet(secs);
    }

    // --------------------------------------------------------------------- //
    //                           Pause controls                              //
    // --------------------------------------------------------------------- //

    /// @notice Stop all trading immediately.
    /// @dev Owner OR agent may call this. The agent gets a brake it can pull on
    ///      its own, but (see `unpause`) it can never release the brake.
    function pause() external onlyOwnerOrAgent {
        _pause();
    }

    /// @notice Resume trading.
    /// @dev Owner only. The agent must never be able to re-enable itself, so a
    ///      compromised agent key cannot undo the owner's (or its own) pause.
    function unpause() external onlyOwner {
        _unpause();
    }

    // --------------------------------------------------------------------- //
    //                           Ownership safety                            //
    // --------------------------------------------------------------------- //

    /// @notice Renouncing ownership is disabled on purpose.
    /// @dev `Ownable.renounceOwnership` would set `owner` to `address(0)`
    ///      forever. With no owner, nobody could ever `withdraw` or `unpause`
    ///      again, so the funds would be stuck and the vault stuck paused. That
    ///      breaks the core promise that the owner can always pull funds out, so
    ///      we override it to always revert. Hand the vault over with the
    ///      two-step `transferOwnership` / `acceptOwnership` instead.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // --------------------------------------------------------------------- //
    //                              Internal                                 //
    // --------------------------------------------------------------------- //

    /// @dev Shared agent-setter used by the constructor and `setAgent`.
    function _setAgent(address newAgent) internal {
        emit AgentSet(agent, newAgent);
        agent = newAgent;
    }
}
