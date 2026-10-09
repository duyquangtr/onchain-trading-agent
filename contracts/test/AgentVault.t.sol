// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @title AgentVault M1a tests
/// @notice Covers roles, deposit, withdraw, pause/unpause, the config setters,
///         and the two-step ownership flow, including every "must revert" case
///         called out in SPEC.md M1a (stranger/agent calling admin functions,
///         the agent trying to unpause, withdraw edge cases, and the ownership
///         handover). Swap and caps are M1b and are not tested here.
contract AgentVaultTest is Test {
    AgentVault internal vault;
    MockERC20 internal usdc;

    // Named test actors so the intent of each call is obvious.
    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal stranger = makeAddr("stranger");
    address internal newOwner = makeAddr("newOwner");

    // Mirror the vault's events so vm.expectEmit can match them.
    event Deposited(address indexed token, address indexed from, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event TokenLimitsSet(address indexed token, bool allowed, uint128 maxPerTrade, uint128 maxPerDay);
    event AdapterSet(address indexed adapter, bool allowed);
    event AgentSet(address indexed previousAgent, address indexed newAgent);
    event CooldownSet(uint32 secs);

    function setUp() public {
        vault = new AgentVault(owner, agent);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        // Fund the owner so they can deposit into the vault.
        usdc.mint(owner, 1_000_000e6);
        vm.prank(owner);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------------ //
    //                           Construction                             //
    // ------------------------------------------------------------------ //

    function test_constructor_setsOwnerAndAgent() public view {
        assertEq(vault.owner(), owner, "owner should be the deployer-chosen owner");
        assertEq(vault.agent(), agent, "agent should be set from the constructor");
        assertEq(vault.cooldown(), 0, "cooldown starts at zero");
        assertFalse(vault.paused(), "vault starts unpaused");
    }

    function test_constructor_emitsAgentSet() public {
        vm.expectEmit(true, true, false, true);
        emit AgentSet(address(0), agent);
        new AgentVault(owner, agent);
    }

    // ------------------------------------------------------------------ //
    //                              Deposit                               //
    // ------------------------------------------------------------------ //

    function test_deposit_pullsTokensAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Deposited(address(usdc), owner, 500e6);

        vm.prank(owner);
        vault.deposit(address(usdc), 500e6);

        assertEq(usdc.balanceOf(address(vault)), 500e6, "vault should hold the deposit");
    }

    function test_deposit_worksWhilePaused() public {
        vm.prank(agent);
        vault.pause();

        vm.prank(owner);
        vault.deposit(address(usdc), 100e6);
        assertEq(usdc.balanceOf(address(vault)), 100e6, "deposit must work while paused");
    }

    function test_deposit_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.deposit(address(usdc), 100e6);
    }

    function test_deposit_revertsForAgent() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vault.deposit(address(usdc), 100e6);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(AgentVault.ZeroAmount.selector);
        vault.deposit(address(usdc), 0);
    }

    // ------------------------------------------------------------------ //
    //                              Withdraw                              //
    // ------------------------------------------------------------------ //

    function test_withdraw_sendsTokensAndEmits() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 500e6);

        vm.expectEmit(true, true, false, true);
        emit Withdrawn(address(usdc), owner, 200e6);

        vm.prank(owner);
        vault.withdraw(address(usdc), 200e6, owner);

        assertEq(usdc.balanceOf(address(vault)), 300e6, "vault balance should drop by the withdrawal");
        assertEq(usdc.balanceOf(owner), 1_000_000e6 - 300e6, "owner should receive the withdrawal");
    }

    /// @dev This is the headline M1a safety property: pausing stops trading but
    ///      never the owner's ability to rescue funds.
    function test_withdraw_worksWhilePaused() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 500e6);

        vm.prank(agent);
        vault.pause();

        vm.prank(owner);
        vault.withdraw(address(usdc), 500e6, owner);
        assertEq(usdc.balanceOf(address(vault)), 0, "owner must be able to withdraw while paused");
    }

    function test_withdraw_revertsForStranger() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 500e6);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.withdraw(address(usdc), 100e6, stranger);
    }

    function test_withdraw_revertsForAgent() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 500e6);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vault.withdraw(address(usdc), 100e6, agent);
    }

    function test_withdraw_revertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(AgentVault.ZeroAmount.selector);
        vault.withdraw(address(usdc), 0, owner);
    }

    function test_withdraw_revertsOnZeroRecipient() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 500e6);

        vm.prank(owner);
        vm.expectRevert(AgentVault.ZeroAddress.selector);
        vault.withdraw(address(usdc), 100e6, address(0));
    }

    function test_withdraw_revertsWhenBalanceTooLow() public {
        // The vault holds nothing; the token itself should reject the transfer.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(vault), 0, 100e6)
        );
        vault.withdraw(address(usdc), 100e6, owner);
    }

    // ------------------------------------------------------------------ //
    //                          Config setters                            //
    // ------------------------------------------------------------------ //

    function test_setTokenLimits_storesAndEmits() public {
        AgentVault.TokenLimits memory limits =
            AgentVault.TokenLimits({allowed: true, maxPerTrade: 5_000e6, maxPerDay: 20_000e6});

        vm.expectEmit(true, false, false, true);
        emit TokenLimitsSet(address(usdc), true, 5_000e6, 20_000e6);

        vm.prank(owner);
        vault.setTokenLimits(address(usdc), limits);

        (bool allowed, uint128 maxPerTrade, uint128 maxPerDay) = vault.tokenLimits(address(usdc));
        assertTrue(allowed, "allowed flag should be stored");
        assertEq(maxPerTrade, 5_000e6, "maxPerTrade should be stored");
        assertEq(maxPerDay, 20_000e6, "maxPerDay should be stored");
    }

    function test_setTokenLimits_revertsForNonOwner() public {
        AgentVault.TokenLimits memory limits =
            AgentVault.TokenLimits({allowed: true, maxPerTrade: 1, maxPerDay: 1});
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setTokenLimits(address(usdc), limits);
    }

    function test_setTokenLimits_revertsOnZeroToken() public {
        AgentVault.TokenLimits memory limits =
            AgentVault.TokenLimits({allowed: true, maxPerTrade: 1, maxPerDay: 1});
        vm.prank(owner);
        vm.expectRevert(AgentVault.ZeroAddress.selector);
        vault.setTokenLimits(address(0), limits);
    }

    function test_setAdapter_storesAndEmits() public {
        address adapter = makeAddr("adapter");

        vm.expectEmit(true, false, false, true);
        emit AdapterSet(adapter, true);

        vm.prank(owner);
        vault.setAdapter(adapter, true);
        assertTrue(vault.allowedAdapters(adapter), "adapter should be allowlisted");

        vm.prank(owner);
        vault.setAdapter(adapter, false);
        assertFalse(vault.allowedAdapters(adapter), "adapter should be removed");
    }

    function test_setAdapter_revertsForNonOwner() public {
        address adapter = makeAddr("adapter");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setAdapter(adapter, true);
    }

    function test_setAdapter_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AgentVault.ZeroAddress.selector);
        vault.setAdapter(address(0), true);
    }

    function test_setAgent_updatesAndEmits() public {
        address newAgent = makeAddr("newAgent");

        vm.expectEmit(true, true, false, false);
        emit AgentSet(agent, newAgent);

        vm.prank(owner);
        vault.setAgent(newAgent);
        assertEq(vault.agent(), newAgent, "agent should be updated");
    }

    function test_setAgent_zeroDisablesAgent() public {
        vm.prank(owner);
        vault.setAgent(address(0));
        assertEq(vault.agent(), address(0), "address(0) should disable the agent");
    }

    function test_setAgent_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setAgent(stranger);
    }

    function test_setCooldown_storesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit CooldownSet(600);

        vm.prank(owner);
        vault.setCooldown(600);
        assertEq(vault.cooldown(), 600, "cooldown should be stored");
    }

    function test_setCooldown_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setCooldown(600);
    }

    // ------------------------------------------------------------------ //
    //                          Pause / unpause                           //
    // ------------------------------------------------------------------ //

    function test_pause_byOwner() public {
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused(), "owner should be able to pause");
    }

    function test_pause_byAgent() public {
        vm.prank(agent);
        vault.pause();
        assertTrue(vault.paused(), "agent should be able to pause (its own circuit breaker)");
    }

    function test_pause_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.NotOwnerOrAgent.selector, stranger));
        vault.pause();
    }

    function test_unpause_byOwner() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused(), "owner should be able to unpause");
    }

    /// @dev Core M1a rule: the agent can pause but must never unpause.
    function test_unpause_revertsForAgent() public {
        vm.prank(agent);
        vault.pause();

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vault.unpause();
    }

    function test_unpause_revertsForStranger() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.unpause();
    }

    function test_pause_revertsWhenAlreadyPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.pause();
    }

    // ------------------------------------------------------------------ //
    //                     Two-step ownership transfer                    //
    // ------------------------------------------------------------------ //

    function test_transferOwnership_isTwoStep() public {
        // Step 1: current owner proposes; ownership does NOT change yet.
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), owner, "owner should not change until accepted");
        assertEq(vault.pendingOwner(), newOwner, "new owner should be pending");

        // Step 2: the pending owner accepts and becomes the owner.
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner, "new owner should take over after accepting");
        assertEq(vault.pendingOwner(), address(0), "pending owner should be cleared");
    }

    function test_acceptOwnership_revertsForNonPending() public {
        vm.prank(owner);
        vault.transferOwnership(newOwner);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.acceptOwnership();
    }

    function test_oldOwnerLosesRightsAfterTransfer() public {
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();

        // The old owner can no longer touch admin functions.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setCooldown(1);

        // The new owner can.
        vm.prank(newOwner);
        vault.setCooldown(1);
        assertEq(vault.cooldown(), 1, "new owner should control settings");
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.transferOwnership(newOwner);
    }
}
