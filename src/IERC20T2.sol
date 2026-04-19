// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20T2 {
    event TransferInitiated(
        address indexed from,
        address indexed to,
        uint256 amount,
        bytes32 indexed tradeId,
        uint256 settlesAt,
        uint256 expiresAt
    );

    event TransferAcknowledged(bytes32 indexed tradeId, address indexed acknowledger);
    event TransferCancelled(bytes32 indexed tradeId, address indexed canceller);
    event TransferRejected(bytes32 indexed tradeId, address indexed rejecter);
    event TransferReclaimed(bytes32 indexed tradeId, address indexed reclaimer);

    function availableBalanceOf(address account) external view returns (uint256);
    function pendingBalanceOf(address account) external view returns (uint256);
    function inFlightBalanceOf(address account) external view returns (uint256);

    function pendingTransferOf(bytes32 tradeId) external view returns (
        address from,
        address to,
        uint256 amount,
        uint256 settlesAt,
        uint256 expiresAt,
        bool exists
    );

    function acknowledge(bytes32 tradeId) external;
    function reject(bytes32 tradeId) external;
    function cancel(bytes32 tradeId) external;
    function reclaim(bytes32 tradeId) external;
    function reclaimBatch(bytes32[] calldata tradeIds) external;

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool);
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool);
}
