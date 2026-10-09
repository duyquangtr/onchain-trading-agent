// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A test-only ERC-20 that burns a flat fee on every transfer, so the
///         recipient receives less than was sent. Used to prove the vault's
///         `deposit` logs the amount actually received, not the amount asked
///         for. Never deployed to a real network.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public immutable fee;

    constructor(uint256 fee_) ERC20("Fee Token", "FEE") {
        fee = fee_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Burns `fee` from the transferred amount so `to` gets `amount - fee`.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value >= fee) {
            super._update(from, to, value - fee);
            super._update(from, address(0xdead), fee);
        } else {
            super._update(from, to, value);
        }
    }
}
