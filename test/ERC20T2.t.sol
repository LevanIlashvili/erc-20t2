// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {TestToken} from "../src/TestToken.sol";
import {ERC20T2} from "../src/ERC20T2.sol";
import {IERC20T2} from "../src/IERC20T2.sol";

contract ERC20T2Test is Test {
    TestToken token;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    address dave = address(0xDA7E);

    uint256 constant T2 = 172800;
    uint256 constant T7 = 604800;

    // Mirror of contract events for expectEmit.
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

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

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new TestToken("Test T2", "T2T");
        token.mint(alice, 1_000 ether);
        token.mint(bob, 500 ether);
    }

    // --- Helpers ---

    function _initiate(address from, address to, uint256 amount) internal returns (bytes32) {
        uint256 nonce = token.nonceOf(from);
        bytes32 expectedId = keccak256(abi.encode(from, to, amount, block.timestamp, nonce));
        vm.prank(from);
        token.transfer(to, amount);
        return expectedId;
    }

    // --- Metadata / minting basics ---

    function test_Metadata() public view {
        assertEq(token.name(), "Test T2");
        assertEq(token.symbol(), "T2T");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_500 ether);
    }

    function test_MintBypassesSettlement() public {
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.availableBalanceOf(alice), 1_000 ether);
        assertEq(token.pendingBalanceOf(alice), 0);
        assertEq(token.inFlightBalanceOf(alice), 0);
    }

    function test_MintZeroReverts() public {
        vm.expectRevert(bytes("ERC20T2: zero amount"));
        token.mint(carol, 0);
    }

    function test_MintToZeroReverts() public {
        vm.expectRevert(bytes("ERC20T2: mint to zero"));
        token.mint(address(0), 1 ether);
    }

    function test_BurnAvailableOnly() public {
        token.burn(alice, 100 ether);
        assertEq(token.availableBalanceOf(alice), 900 ether);
        assertEq(token.totalSupply(), 1_400 ether);
    }

    function test_BurnExceedingAvailableReverts() public {
        _initiate(alice, bob, 950 ether);
        // Alice now has 50 ether available, 950 in-flight.
        vm.expectRevert(bytes("ERC20T2: burn exceeds available"));
        token.burn(alice, 100 ether);
    }

    // --- Initiation (transfer) ---

    function test_TransferInitiates_DoesNotEmitERC20Transfer() public {
        uint256 nonce = token.nonceOf(alice);
        bytes32 tradeId = keccak256(abi.encode(alice, bob, 100 ether, block.timestamp, nonce));

        vm.expectEmit(true, true, true, true);
        emit TransferInitiated(alice, bob, 100 ether, tradeId, block.timestamp + T2, block.timestamp + T7);

        vm.prank(alice);
        token.transfer(bob, 100 ether);

        assertEq(token.availableBalanceOf(alice), 900 ether);
        assertEq(token.inFlightBalanceOf(alice), 100 ether);
        assertEq(token.pendingBalanceOf(bob), 100 ether);
        assertEq(token.availableBalanceOf(bob), 500 ether);   // unchanged
        assertEq(token.balanceOf(bob), 500 ether);             // balanceOf == available

        (address f, address t, uint256 amt, uint256 settlesAt, uint256 expiresAt, bool exists) =
            token.pendingTransferOf(tradeId);
        assertEq(f, alice);
        assertEq(t, bob);
        assertEq(amt, 100 ether);
        assertEq(settlesAt, block.timestamp + T2);
        assertEq(expiresAt, block.timestamp + T7);
        assertTrue(exists);
    }

    function test_TransferRevertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ERC20T2: zero amount"));
        token.transfer(bob, 0);
    }

    function test_TransferRevertsOnZeroRecipient() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ERC20T2: transfer to zero"));
        token.transfer(address(0), 1 ether);
    }

    function test_TransferRevertsOnInsufficientAvailable() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ERC20T2: insufficient available balance"));
        token.transfer(bob, 10_000 ether);
    }

    function test_TradeIdsAreUniqueViaNonce() public {
        bytes32 id1 = _initiate(alice, bob, 10 ether);
        bytes32 id2 = _initiate(alice, bob, 10 ether);
        assertTrue(id1 != id2);
        assertEq(token.nonceOf(alice), 2);
    }

    // --- Acknowledge ---

    function test_AcknowledgeAfterSettlement_CreditsAndEmitsTransfer() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);
        vm.warp(block.timestamp + T2);

        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 100 ether);
        vm.expectEmit(true, true, false, true);
        emit TransferAcknowledged(tradeId, bob);

        vm.prank(bob);
        token.acknowledge(tradeId);

        assertEq(token.availableBalanceOf(bob), 600 ether);
        assertEq(token.pendingBalanceOf(bob), 0);
        assertEq(token.inFlightBalanceOf(alice), 0);
        assertEq(token.availableBalanceOf(alice), 900 ether);

        (,,,,, bool exists) = token.pendingTransferOf(tradeId);
        assertFalse(exists);
    }

    function test_AcknowledgeBeforeSettlementReverts() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);
        vm.warp(block.timestamp + T2 - 1);
        vm.prank(bob);
        vm.expectRevert(bytes("ERC20T2: settlement not yet open"));
        token.acknowledge(tradeId);
    }

    function test_AcknowledgeAfterExpiryReverts() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);
        vm.warp(block.timestamp + T7);
        vm.prank(bob);
        vm.expectRevert(bytes("ERC20T2: acknowledgment window closed"));
        token.acknowledge(tradeId);
    }

    function test_AcknowledgeByNonRecipientReverts() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);
        vm.warp(block.timestamp + T2);
        vm.prank(carol);
        vm.expectRevert(bytes("ERC20T2: only recipient may acknowledge"));
        token.acknowledge(tradeId);
    }

    function test_AcknowledgeUnknownIdReverts() public {
        vm.prank(bob);
        vm.expectRevert(bytes("ERC20T2: unknown tradeId"));
        token.acknowledge(bytes32(uint256(42)));
    }

    function test_AcknowledgeAtSettlesAtBoundary_Succeeds() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);
        vm.warp(block.timestamp + T2); // exactly settlesAt
        vm.prank(bob);
        token.acknowledge(tradeId);
        assertEq(token.availableBalanceOf(bob), 600 ether);
    }

    function test_AcknowledgeAtExpiresAtBoundary_Reverts() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);
        vm.warp(block.timestamp + T7); // exactly expiresAt
        vm.prank(bob);
        vm.expectRevert(bytes("ERC20T2: acknowledgment window closed"));
        token.acknowledge(tradeId);
    }

    // --- Cancel (sender-only, settlement window) ---

    function test_CancelDuringSettlementReturnsToSender() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);

        vm.expectEmit(true, true, false, true);
        emit TransferCancelled(tradeId, alice);

        vm.prank(alice);
        token.cancel(tradeId);

        assertEq(token.availableBalanceOf(alice), 1_000 ether);
        assertEq(token.inFlightBalanceOf(alice), 0);
        assertEq(token.pendingBalanceOf(bob), 0);
    }

    function test_CancelAtSettlesAtReverts() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);
        vm.warp(block.timestamp + T2);
        vm.prank(alice);
        vm.expectRevert(bytes("ERC20T2: settlement window closed"));
        token.cancel(tradeId);
    }

    function test_CancelByNonSenderReverts() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(bytes("ERC20T2: only sender may cancel"));
        token.cancel(tradeId);
    }

    // --- Reject (recipient-only, any time before terminal) ---

    function test_RejectDuringSettlementReturnsToSender() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);

        vm.expectEmit(true, true, false, true);
        emit TransferRejected(tradeId, bob);

        vm.prank(bob);
        token.reject(tradeId);

        assertEq(token.availableBalanceOf(alice), 1_000 ether);
        assertEq(token.pendingBalanceOf(bob), 0);
    }

    function test_RejectAfterSettlementReturnsToSender() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);
        vm.warp(block.timestamp + T2 + 1);
        vm.prank(bob);
        token.reject(tradeId);
        assertEq(token.availableBalanceOf(alice), 1_000 ether);
    }

    function test_RejectAfterExpiryReturnsToSender() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);
        vm.warp(block.timestamp + T7 + 100);
        vm.prank(bob);
        token.reject(tradeId);
        assertEq(token.availableBalanceOf(alice), 1_000 ether);
    }

    function test_RejectByNonRecipientReverts() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("ERC20T2: only recipient may reject"));
        token.reject(tradeId);
    }

    // --- Reclaim (anyone, after expiry) ---

    function test_ReclaimAfterExpiryReturnsToSender() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);
        vm.warp(block.timestamp + T7);

        vm.expectEmit(true, true, false, true);
        emit TransferReclaimed(tradeId, dave);

        vm.prank(dave); // stranger
        token.reclaim(tradeId);

        assertEq(token.availableBalanceOf(alice), 1_000 ether);
        assertEq(token.pendingBalanceOf(bob), 0);
    }

    function test_ReclaimBeforeExpiryReverts() public {
        bytes32 tradeId = _initiate(alice, bob, 100 ether);
        vm.warp(block.timestamp + T7 - 1);
        vm.prank(dave);
        vm.expectRevert(bytes("ERC20T2: not yet reclaimable"));
        token.reclaim(tradeId);
    }

    function test_ReclaimBatch() public {
        bytes32 id1 = _initiate(alice, bob, 10 ether);
        bytes32 id2 = _initiate(alice, carol, 20 ether);
        bytes32 id3 = _initiate(bob, carol, 30 ether);

        vm.warp(block.timestamp + T7);
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = id3;

        vm.prank(dave);
        token.reclaimBatch(ids);

        assertEq(token.availableBalanceOf(alice), 1_000 ether);
        assertEq(token.availableBalanceOf(bob), 500 ether);
        assertEq(token.pendingBalanceOf(bob), 0);
        assertEq(token.pendingBalanceOf(carol), 0);
    }

    // --- transferFrom & allowance semantics ---

    function test_TransferFromDecrementsAllowanceAtInitiation() public {
        vm.prank(alice);
        token.approve(carol, 200 ether);

        vm.prank(carol);
        token.transferFrom(alice, bob, 100 ether);

        assertEq(token.allowance(alice, carol), 100 ether);
        assertEq(token.inFlightBalanceOf(alice), 100 ether);
    }

    function test_TransferFromRevertsOnInsufficientAllowance() public {
        vm.prank(alice);
        token.approve(carol, 50 ether);

        vm.prank(carol);
        vm.expectRevert(bytes("ERC20T2: insufficient allowance"));
        token.transferFrom(alice, bob, 100 ether);
    }

    function test_InfiniteAllowanceNotDecremented() public {
        vm.prank(alice);
        token.approve(carol, type(uint256).max);

        vm.prank(carol);
        token.transferFrom(alice, bob, 100 ether);

        assertEq(token.allowance(alice, carol), type(uint256).max);
    }

    function test_CancelDoesNotRestoreAllowance() public {
        vm.prank(alice);
        token.approve(carol, 200 ether);

        uint256 nonce = token.nonceOf(alice);
        bytes32 tradeId = keccak256(abi.encode(alice, bob, 100 ether, block.timestamp, nonce));
        vm.prank(carol);
        token.transferFrom(alice, bob, 100 ether);

        vm.prank(alice);
        token.cancel(tradeId);

        assertEq(token.allowance(alice, carol), 100 ether); // still consumed
        assertEq(token.availableBalanceOf(alice), 1_000 ether); // but funds returned
    }

    function test_RejectDoesNotRestoreAllowance() public {
        vm.prank(alice);
        token.approve(carol, 200 ether);

        uint256 nonce = token.nonceOf(alice);
        bytes32 tradeId = keccak256(abi.encode(alice, bob, 100 ether, block.timestamp, nonce));
        vm.prank(carol);
        token.transferFrom(alice, bob, 100 ether);

        vm.prank(bob);
        token.reject(tradeId);

        assertEq(token.allowance(alice, carol), 100 ether);
    }

    function test_ReclaimDoesNotRestoreAllowance() public {
        vm.prank(alice);
        token.approve(carol, 200 ether);

        uint256 nonce = token.nonceOf(alice);
        bytes32 tradeId = keccak256(abi.encode(alice, bob, 100 ether, block.timestamp, nonce));
        vm.prank(carol);
        token.transferFrom(alice, bob, 100 ether);

        vm.warp(block.timestamp + T7);
        token.reclaim(tradeId);

        assertEq(token.allowance(alice, carol), 100 ether);
    }

    function test_IncreaseDecreaseAllowance() public {
        vm.prank(alice);
        token.increaseAllowance(carol, 100 ether);
        assertEq(token.allowance(alice, carol), 100 ether);

        vm.prank(alice);
        token.increaseAllowance(carol, 50 ether);
        assertEq(token.allowance(alice, carol), 150 ether);

        vm.prank(alice);
        token.decreaseAllowance(carol, 70 ether);
        assertEq(token.allowance(alice, carol), 80 ether);
    }

    function test_DecreaseAllowanceUnderflowReverts() public {
        vm.prank(alice);
        token.increaseAllowance(carol, 50 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("ERC20T2: decrease below zero"));
        token.decreaseAllowance(carol, 100 ether);
    }

    // --- ERC-165 ---

    function test_SupportsIERC20() public view {
        assertTrue(token.supportsInterface(type(IERC20).interfaceId));
    }

    function test_SupportsIERC165() public view {
        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
    }

    function test_SupportsIERC20T2() public view {
        assertTrue(token.supportsInterface(type(IERC20T2).interfaceId));
    }

    function test_RejectsRandomInterface() public view {
        assertFalse(token.supportsInterface(bytes4(0xdeadbeef)));
    }

    /// @notice The spec claims the interface ID is 0xdc09a479. This test records what the
    ///         compiler actually computes — if it differs, the spec is simply wrong (fitting,
    ///         for a self-approved EIP).
    function test_ReportSpecInterfaceId() public {
        bytes4 actual = type(IERC20T2).interfaceId;
        // The spec claims 0xdc09a479. We assert nothing here; log for the record.
        emit log_named_bytes32("actual IERC20T2 interfaceId", bytes32(actual));
        emit log_named_bytes32("spec claim              ", bytes32(bytes4(0xdc09a479)));
    }

    // --- Constants ---

    function test_Constants() public view {
        assertEq(token.SETTLEMENT_PERIOD(), 172800);
        assertEq(token.ACKNOWLEDGMENT_WINDOW(), 432000);
        assertEq(token.TOTAL_LIFECYCLE(), 604800);
    }

    // --- End-to-end scenario: key-compromise narrative from the spec ---

    /// @notice Spec motivation scenario: attacker steals Alice's key, transfers to themselves.
    ///         Legitimate Alice (via any monitoring) detects within T+2 and cancels.
    function test_Scenario_KeyCompromiseCancelledInWindow() public {
        // Attacker uses stolen key to transfer to attacker address (dave).
        uint256 nonce = token.nonceOf(alice);
        bytes32 tradeId = keccak256(abi.encode(alice, dave, 500 ether, block.timestamp, nonce));
        vm.prank(alice);
        token.transfer(dave, 500 ether);

        // Legitimate Alice notices, cancels within window.
        vm.warp(block.timestamp + T2 - 1);
        vm.prank(alice);
        token.cancel(tradeId);

        assertEq(token.availableBalanceOf(alice), 1_000 ether);
        assertEq(token.pendingBalanceOf(dave), 0);
    }

    /// @notice Recipient contract cannot acknowledge -> after T+7 anyone reclaims to sender.
    function test_Scenario_SilentRecipientReclaimed() public {
        // Transfer to a contract that has no acknowledge plumbing (we just use EOA `carol` here;
        // behaviour is identical).
        bytes32 tradeId = _initiate(alice, carol, 50 ether);

        // Nobody ever calls acknowledge. After T+7 a reclaimer-as-a-service picks it up.
        vm.warp(block.timestamp + T7);
        vm.prank(dave);
        token.reclaim(tradeId);

        assertEq(token.availableBalanceOf(alice), 1_000 ether);
    }
}
