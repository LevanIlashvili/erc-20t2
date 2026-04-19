// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20T2} from "./IERC20T2.sol";

/// @title ERC20T2 - Deferred-Settlement Fungible Token (EIP-11547)
/// @notice Transfers are a three-phase lifecycle: initiate -> settle (T+2) -> acknowledge (by T+7).
abstract contract ERC20T2 is IERC20, IERC165, IERC20T2 {
    uint256 public constant SETTLEMENT_PERIOD = 172800;      // T+2
    uint256 public constant ACKNOWLEDGMENT_WINDOW = 432000;  // 5 days
    uint256 public constant TOTAL_LIFECYCLE = 604800;        // T+7

    struct PendingTransfer {
        address from;
        address to;
        uint256 amount;
        uint256 settlesAt;
        uint256 expiresAt;
    }

    mapping(address => uint256) private _available;
    mapping(address => uint256) private _pending;
    mapping(address => uint256) private _inFlight;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(bytes32 => PendingTransfer) private _pendingTransfers;
    mapping(address => uint256) private _nonces;

    uint256 private _totalSupply;
    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    // ---- ERC-20 metadata ----
    function name() external view returns (string memory) { return _name; }
    function symbol() external view returns (string memory) { return _symbol; }
    function decimals() external pure virtual returns (uint8) { return 18; }
    function totalSupply() external view returns (uint256) { return _totalSupply; }

    // ---- Balance queries ----
    function balanceOf(address account) external view returns (uint256) {
        return _available[account];
    }
    function availableBalanceOf(address account) external view returns (uint256) {
        return _available[account];
    }
    function pendingBalanceOf(address account) external view returns (uint256) {
        return _pending[account];
    }
    function inFlightBalanceOf(address account) external view returns (uint256) {
        return _inFlight[account];
    }
    function nonceOf(address account) external view returns (uint256) {
        return _nonces[account];
    }
    function pendingTransferOf(bytes32 tradeId) external view returns (
        address from,
        address to,
        uint256 amount,
        uint256 settlesAt,
        uint256 expiresAt,
        bool exists
    ) {
        PendingTransfer memory p = _pendingTransfers[tradeId];
        exists = p.settlesAt != 0;
        return (p.from, p.to, p.amount, p.settlesAt, p.expiresAt, exists);
    }

    // ---- Allowances ----
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        uint256 newValue = _allowances[msg.sender][spender] + addedValue;
        _allowances[msg.sender][spender] = newValue;
        emit Approval(msg.sender, spender, newValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 current = _allowances[msg.sender][spender];
        require(current >= subtractedValue, "ERC20T2: decrease below zero");
        uint256 newValue;
        unchecked { newValue = current - subtractedValue; }
        _allowances[msg.sender][spender] = newValue;
        emit Approval(msg.sender, spender, newValue);
        return true;
    }

    // ---- Transfer lifecycle ----
    function transfer(address to, uint256 amount) external returns (bool) {
        _initiate(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= amount, "ERC20T2: insufficient allowance");
        if (allowed != type(uint256).max) {
            unchecked { _allowances[from][msg.sender] = allowed - amount; }
            emit Approval(from, msg.sender, allowed - amount);
        }
        _initiate(from, to, amount);
        return true;
    }

    function acknowledge(bytes32 tradeId) external {
        PendingTransfer memory p = _pendingTransfers[tradeId];
        require(p.settlesAt != 0, "ERC20T2: unknown tradeId");
        require(msg.sender == p.to, "ERC20T2: only recipient may acknowledge");
        require(block.timestamp >= p.settlesAt, "ERC20T2: settlement not yet open");
        require(block.timestamp < p.expiresAt, "ERC20T2: acknowledgment window closed");

        delete _pendingTransfers[tradeId];
        unchecked {
            _pending[p.to] -= p.amount;
            _inFlight[p.from] -= p.amount;
        }
        _available[p.to] += p.amount;

        emit Transfer(p.from, p.to, p.amount);
        emit TransferAcknowledged(tradeId, msg.sender);
    }

    function reject(bytes32 tradeId) external {
        PendingTransfer memory p = _pendingTransfers[tradeId];
        require(p.settlesAt != 0, "ERC20T2: unknown tradeId");
        require(msg.sender == p.to, "ERC20T2: only recipient may reject");

        delete _pendingTransfers[tradeId];
        unchecked {
            _pending[p.to] -= p.amount;
            _inFlight[p.from] -= p.amount;
        }
        _available[p.from] += p.amount;

        emit TransferRejected(tradeId, msg.sender);
    }

    function cancel(bytes32 tradeId) external {
        PendingTransfer memory p = _pendingTransfers[tradeId];
        require(p.settlesAt != 0, "ERC20T2: unknown tradeId");
        require(msg.sender == p.from, "ERC20T2: only sender may cancel");
        require(block.timestamp < p.settlesAt, "ERC20T2: settlement window closed");

        delete _pendingTransfers[tradeId];
        unchecked {
            _pending[p.to] -= p.amount;
            _inFlight[p.from] -= p.amount;
        }
        _available[p.from] += p.amount;

        emit TransferCancelled(tradeId, msg.sender);
    }

    function reclaim(bytes32 tradeId) public {
        PendingTransfer memory p = _pendingTransfers[tradeId];
        require(p.settlesAt != 0, "ERC20T2: unknown tradeId");
        require(block.timestamp >= p.expiresAt, "ERC20T2: not yet reclaimable");

        delete _pendingTransfers[tradeId];
        unchecked {
            _pending[p.to] -= p.amount;
            _inFlight[p.from] -= p.amount;
        }
        _available[p.from] += p.amount;

        emit TransferReclaimed(tradeId, msg.sender);
    }

    function reclaimBatch(bytes32[] calldata tradeIds) external {
        uint256 n = tradeIds.length;
        for (uint256 i = 0; i < n; ) {
            reclaim(tradeIds[i]);
            unchecked { ++i; }
        }
    }

    // ---- Internal ----
    function _initiate(address from, address to, uint256 amount) internal returns (bytes32 tradeId) {
        require(to != address(0), "ERC20T2: transfer to zero");
        require(amount > 0, "ERC20T2: zero amount");
        require(_available[from] >= amount, "ERC20T2: insufficient available balance");

        unchecked { _available[from] -= amount; }
        _inFlight[from] += amount;
        _pending[to] += amount;

        uint256 nonce = _nonces[from]++;
        uint256 settlesAt = block.timestamp + SETTLEMENT_PERIOD;
        uint256 expiresAt = settlesAt + ACKNOWLEDGMENT_WINDOW;
        tradeId = keccak256(abi.encode(from, to, amount, block.timestamp, nonce));

        _pendingTransfers[tradeId] = PendingTransfer({
            from: from,
            to: to,
            amount: amount,
            settlesAt: settlesAt,
            expiresAt: expiresAt
        });

        emit TransferInitiated(from, to, amount, tradeId, settlesAt, expiresAt);
    }

    /// @dev Minted tokens bypass the settlement delay (no counterparty to unwind from).
    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "ERC20T2: mint to zero");
        require(amount > 0, "ERC20T2: zero amount");
        _totalSupply += amount;
        _available[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @dev In-flight tokens cannot be burned; they must reach a terminal state first.
    function _burn(address from, uint256 amount) internal {
        require(amount > 0, "ERC20T2: zero amount");
        require(_available[from] >= amount, "ERC20T2: burn exceeds available");
        unchecked {
            _available[from] -= amount;
            _totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    // ---- ERC-165 ----
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC20T2).interfaceId;
    }
}
