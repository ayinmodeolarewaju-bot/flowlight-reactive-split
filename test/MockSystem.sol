// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Stand-in for the Omni system contract and for a destination callback proxy.
contract MockSystem {
    event Subscribed(address indexed subscriber, uint256 chainId, address contract_, uint256 topic0);
    event Unsubscribed(address indexed subscriber, uint256 chainId, address contract_, uint256 topic0);
    event CallbackCaptured(uint256 chainId, address recipient, uint64 gasLimit, bytes payload);

    uint256 public debtOf;

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256,
        uint256,
        uint256
    ) external {
        emit Subscribed(msg.sender, chainId_, contract_, topic0_);
    }

    function unsubscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256,
        uint256,
        uint256
    ) external {
        emit Unsubscribed(msg.sender, chainId_, contract_, topic0_);
    }

    function requestCallback(ISystemContract.CallbackVersion, bytes memory) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        emit CallbackCaptured(config_.chainId, config_.recipient, config_.gasLimit, config_.payload);
    }

    function debt(address) external view returns (uint256) {
        return debtOf;
    }

    function setDebt(uint256 debt_) external {
        debtOf = debt_;
    }

    receive() external payable {}
}
