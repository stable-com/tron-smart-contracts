// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { EIP712Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ILiquidityPool } from "./interfaces/ILiquidityPool.sol";
import { ICrossChainHTLC } from "./interfaces/ICrossChainHTLC.sol";
import { IAllowanceTransfer } from "./interfaces/IAllowanceTransfer.sol";
import { IERC20Permit } from "./interfaces/IERC20Permit.sol";
import { SafePermit } from "./libraries/SafePermit.sol";

/**
 * @title LiquidityPool
 * @notice Protocol-owned liquidity pool for 1:1 swaps and cross-chain swaps
 */
contract LiquidityPool is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlEnumerableUpgradeable,
    EIP712Upgradeable,
    ILiquidityPool
{
    using SafeERC20 for IERC20;
    using SafePermit for IERC20Permit;
    using SafePermit for IAllowanceTransfer;
    using Address for address payable;

    // ========= Roles =========
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
    bytes32 public constant ROUTING_MODULE_ROLE = keccak256("ROUTING_MODULE_ROLE");
    bytes32 public constant CROSS_CHAIN_MANAGER_ROLE = keccak256("CROSS_CHAIN_MANAGER_ROLE");

    // ========= EIP-712 =========
    bytes32 private constant SWAP_LOCAL_TYPEHASH =
        keccak256(
            "SwapLocal(uint256 amountIn,address tokenIn,address tokenOut,address recipient,uint64 deadline,address user,uint256 nonce)"
        );

    bytes32 private constant SWAP_LOCAL_WITH_FEE_TYPEHASH =
        keccak256(
            "SwapLocalWithFee(uint256 amountIn,address tokenIn,address tokenOut,address recipient,uint64 deadline,address user,uint256 nonce,uint256 executionFeeNative)"
        );

    bytes32 private constant SWAP_LOCAL_WITH_SIGNATURE_TYPEHASH =
        keccak256(
            "SwapLocalWithSignature(uint256 amountIn,address tokenIn,address tokenOut,address recipient,uint64 deadline,address user,uint256 nonce,uint256 fee)"
        );

    bytes32 private constant LOCK_SOURCE_WITH_SIGNATURE_TYPEHASH =
        keccak256(
            "LockSourceWithSignature(uint256 amount,address token,bytes32 secretHash,address user,uint256 nonce,uint256 fee,address sessionAddress)"
        );

    bytes32 private constant LOCK_SOURCE_WITH_PERMIT_TYPEHASH =
        keccak256("LockSourceWithPermit(uint256 nonce,uint256 fee,address sessionAddress)");

    bytes32 private constant LOCK_SOURCE_WITH_PERMIT2_TYPEHASH =
        keccak256("LockSourceWithPermit2(uint256 nonce,uint256 fee,address sessionAddress)");

    bytes32 private constant SWAP_WITH_PERMIT_TYPEHASH =
        keccak256("SwapWithPermit(uint256 nonce,uint256 fee,address recipient)");

    bytes32 private constant SWAP_WITH_PERMIT2_TYPEHASH =
        keccak256("SwapWithPermit2(uint256 nonce,uint256 fee,address recipient)");

    // ========= Constants =========
    uint256 public constant FEE_DENOMINATOR = 1_000_000; // 100% = 1000000, 10000 = 1%, 100 = 0.01%
    uint256 public constant MAX_PROTOCOL_FEE = 100_000; // 10% maximum fee rate

    // ========= Storage =========
    address public permit2;
    address public maintainer;

    mapping(address => bool) public isWhitelisted; // token => whitelisted
    mapping(address => uint8) public tokenDecimals; // token => decimals
    mapping(address => ILiquidityPool.LiquidityThresholds) public liquidityThresholds; // token => thresholds
    mapping(bytes32 => uint256) public lockedAmount; // secretHash => amount
    mapping(address => uint256) public totalLockedByToken; // token => total locked
    mapping(address => uint256) public lastNonce; // user => last used nonce
    mapping(address => uint256) public protocolFeeByToken; // token => fee rate (1000000 = 100%, 10000 = 1%)
    mapping(address => bool) public feeEnabledByToken; // token => enabled fee
    mapping(address => uint256) public collectedFeesByToken; // token => collected fees

    // ========= Events =========
    event TokenSetup(
        address indexed token,
        bool enabled,
        uint8 decimals,
        uint256 X,
        uint256 Y,
        uint256 Z,
        uint256 protocolFee
    );
    event LiquidityDeposited(address token, uint256 amount, address from);
    event LiquidityWithdrawn(address token, uint256 amount, address to);
    event SwapLocalExecuted(
        address user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient,
        uint256 executionFeeNative
    );
    event Locked(bytes32 secretHash, address token, uint256 amount, uint64 untilTs);
    event TransferredToRecipient(
        bytes32 secretHash,
        address token,
        address to,
        uint256 amount
    );
    event Unlocked(bytes32 secretHash, address token, uint256 amount);
    event ProtocolFeeCollected(address token, uint256 protocolFee);
    event MaintainerSet(address maintainer);
    event ProtocolFeeEnabledForTokenUpdated(address token, bool enabled);
    event NativeWithdrawn(address to, uint256 amount, address sender);
    event FeesWithdrawn(address[] tokens, uint256[] amounts, address to);

    // ========= Errors =========
    error NotWhitelisted(address token);
    error InsufficientReserves();
    error DeadlineExpired();
    error InvalidSignature();
    error LockNotFound();
    error InsufficientUnlockedFunds();
    error InvalidUnlockAmount();
    error InvalidNonce();
    error InvalidThresholdsConfig();
    error InvalidChainId();
    error AmountTooSmallForFee();
    error FeeOnTransferNotSupported();
    error TransferBalanceMismatch();
    error Permit2AmountTooHigh();
    error InvalidFeeRate();
    error FeeMismatch(uint256 expected, uint256 actual);

    // ========= Init =========
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address crossChainManager,
        address poolManager,
        address maintainerAddress,
        address permit2Address
    ) public virtual initializer {
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControlEnumerable_init();
        __EIP712_init("LiquidityPool", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CROSS_CHAIN_MANAGER_ROLE, crossChainManager);
        _grantRole(POOL_MANAGER_ROLE, poolManager);
        maintainer = maintainerAddress;
        permit2 = permit2Address;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setMaintainer(address newMaintainer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maintainer = newMaintainer;
        emit MaintainerSet(newMaintainer);
    }

    function setFeeEnabledForToken(
        address token,
        bool enabled
    ) external onlyRole(POOL_MANAGER_ROLE) {
        feeEnabledByToken[token] = enabled;
        emit ProtocolFeeEnabledForTokenUpdated(token, enabled);
    }

    function setupToken(
        address token,
        bool status,
        uint256 X,
        uint256 Y,
        uint256 Z,
        uint256 protocolFee
    ) external onlyRole(POOL_MANAGER_ROLE) {
        if (Y <= X) revert InvalidThresholdsConfig();
        if (Z > (Y - X)) revert InvalidThresholdsConfig();
        if (Z == 0) revert InvalidThresholdsConfig();
        if (protocolFee > MAX_PROTOCOL_FEE) revert InvalidFeeRate();

        isWhitelisted[token] = status;
        if (tokenDecimals[token] == 0) {
            tokenDecimals[token] = IERC20Metadata(token).decimals();
        }
        liquidityThresholds[token] = ILiquidityPool.LiquidityThresholds(X, Y, Z);
        protocolFeeByToken[token] = protocolFee;
        emit TokenSetup(token, status, tokenDecimals[token], X, Y, Z, protocolFee);
    }

    // ========= Liquidity Ops (admin only) =========
    function depositLiquidity(
        address token,
        uint256 amount
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _validateBalanceChange(token, balanceBefore, amount);
        emit LiquidityDeposited(token, amount, msg.sender);
    }

    function withdrawLiquidity(
        address token,
        uint256 amount
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        uint256 available = _getAvailableLiquidity(token);
        if (available < amount) revert InsufficientUnlockedFunds();
        _transferWithBalanceCheck(token, msg.sender, amount);
        emit LiquidityWithdrawn(token, amount, msg.sender);
    }

    function withdrawNative(
        address payable to,
        uint256 amount
    ) external onlyRole(CROSS_CHAIN_MANAGER_ROLE) nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");
        require(amount <= address(this).balance, "Insufficient balance");

        to.sendValue(amount);

        emit NativeWithdrawn(to, amount, msg.sender);
    }

    function withdrawFees(
        address[] calldata tokens,
        address to
    ) external onlyRole(CROSS_CHAIN_MANAGER_ROLE) nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(tokens.length > 0, "Empty arrays");

        uint256[] memory withdrawnAmounts = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 withdrawAmount = collectedFeesByToken[token];

            if (withdrawAmount > 0) {
                collectedFeesByToken[token] = 0;
                _transferWithBalanceCheck(token, to, withdrawAmount);
            }

            withdrawnAmounts[i] = withdrawAmount;
        }

        emit FeesWithdrawn(tokens, withdrawnAmounts, to);
    }

    // ========= Views =========
    function getReserves(address token) external view override returns (uint256 amount) {
        return IERC20(token).balanceOf(address(this));
    }

    function getAvailableLiquidity(address token) external view override returns (uint256) {
        return _getAvailableLiquidity(token);
    }

    function getCollectedFees(address[] calldata tokens) external view returns (uint256[] memory fees) {
        fees = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            fees[i] = collectedFeesByToken[tokens[i]];
        }
        return fees;
    }

    function _getAvailableLiquidity(address token) internal view returns (uint256) {
        uint256 totalBalance = IERC20(token).balanceOf(address(this));
        uint256 locked = totalLockedByToken[token];
        uint256 fees = collectedFeesByToken[token];
        return totalBalance - locked - fees;
    }

    // ========= Local Swap =========
    function singleChainSwap(
        SwapLocal calldata params,
        bytes calldata maintainerSig,
        uint256 executionFeeNative
    ) external payable nonReentrant whenNotPaused {
        if (msg.value != executionFeeNative) revert FeeMismatch(executionFeeNative, msg.value);

        uint256 balanceBefore = IERC20(params.tokenIn).balanceOf(address(this));
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        _validateBalanceChange(params.tokenIn, balanceBefore, params.amountIn);
        _executeSwapWithFee(params, maintainerSig, msg.sender, executionFeeNative);
    }

    function singleChainSwapWithPermit(
        SwapLocalWithPermit calldata params,
        bytes calldata maintainerSig
    ) external onlyRole(CROSS_CHAIN_MANAGER_ROLE) nonReentrant whenNotPaused {
        bytes32 structHash = keccak256(
            abi.encode(SWAP_WITH_PERMIT_TYPEHASH, params.base.nonce, params.permit.fee, params.base.recipient)
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), params.permit.userSignature);
        if (signer != params.user) revert InvalidSignature();

        uint256 permitAmount = params.base.amountIn + params.permit.fee;
        IERC20Permit token = IERC20Permit(params.base.tokenIn);
        token.safePermit(
            params.user,
            address(this),
            permitAmount,
            params.permit.deadline,
            params.permit.v,
            params.permit.r,
            params.permit.s
        );
        uint256 balanceBefore = IERC20(params.base.tokenIn).balanceOf(address(this));
        IERC20(params.base.tokenIn).safeTransferFrom(params.user, address(this), permitAmount);
        _validateBalanceChange(params.base.tokenIn, balanceBefore, permitAmount);
        collectedFeesByToken[params.base.tokenIn] += params.permit.fee;
        _executeSwap(params.base, maintainerSig, params.user);
    }

    function singleChainSwapWithPermit2(
        SwapLocalWithPermit2 calldata params,
        bytes calldata maintainerSig
    ) external onlyRole(CROSS_CHAIN_MANAGER_ROLE) nonReentrant whenNotPaused {
        bytes32 structHash = keccak256(
            abi.encode(SWAP_WITH_PERMIT2_TYPEHASH, params.base.nonce, params.permit2.fee, params.base.recipient)
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), params.permit2.userSignature);
        if (signer != params.user) revert InvalidSignature();

        IAllowanceTransfer.PermitSingle memory permitSingle = abi.decode(
            params.permit2.permit2Data,
            (IAllowanceTransfer.PermitSingle)
        );
        uint256 permit2Amount = params.base.amountIn + params.permit2.fee;
        if (permit2Amount > type(uint160).max) revert Permit2AmountTooHigh();

        IAllowanceTransfer(permit2).safePermit2(
            params.user,
            permitSingle,
            params.permit2.permit2Signature
        );

        uint256 balanceBefore = IERC20(params.base.tokenIn).balanceOf(address(this));
        IAllowanceTransfer(permit2).transferFrom(
            params.user,
            address(this),
            uint160(permit2Amount),
            params.base.tokenIn
        );
        _validateBalanceChange(params.base.tokenIn, balanceBefore, permit2Amount);
        collectedFeesByToken[params.base.tokenIn] += params.permit2.fee;
        _executeSwap(params.base, maintainerSig, params.user);
    }

    function singleChainSwapWithSignature(
        SwapLocal calldata base,
        SignatureData calldata signatureData,
        bytes calldata maintainerSig
    ) external onlyRole(CROSS_CHAIN_MANAGER_ROLE) nonReentrant whenNotPaused {
        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_LOCAL_WITH_SIGNATURE_TYPEHASH,
                base.amountIn,
                base.tokenIn,
                base.tokenOut,
                base.recipient,
                base.deadline,
                signatureData.user,
                base.nonce,
                signatureData.fee
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signatureData.userSignature);
        if (signer != signatureData.user) revert InvalidSignature();

        uint256 totalAmountIn = base.amountIn + signatureData.fee;
        uint256 balanceBefore = IERC20(base.tokenIn).balanceOf(address(this));
        IERC20(base.tokenIn).safeTransferFrom(signatureData.user, address(this), totalAmountIn);
        _validateBalanceChange(base.tokenIn, balanceBefore, totalAmountIn);
        collectedFeesByToken[base.tokenIn] += signatureData.fee;
        _executeSwap(base, maintainerSig, signatureData.user);
    }

    // ========= Cross-chain module =========
    function lockSource(
        ICrossChainHTLC.Base calldata base,
        uint256 nonce,
        uint64 untilTs
    ) external onlyRole(ROUTING_MODULE_ROLE) nonReentrant whenNotPaused {
        _validateAndUpdateNonce(base.user, nonce);

        uint256 balanceBefore = IERC20(base.token).balanceOf(address(this));
        IERC20(base.token).safeTransferFrom(base.user, address(this), base.amount);
        _validateBalanceChange(base.token, balanceBefore, base.amount);

        _lockSource(base.secretHash, base.token, base.amount, untilTs);
    }

    function lockSourceWithPermit(
        ICrossChainHTLC.Base calldata base,
        uint256 nonce,
        uint64 untilTs,
        PermitData calldata permitData,
        address sessionAddress
    ) external onlyRole(ROUTING_MODULE_ROLE) nonReentrant whenNotPaused {
        _validateAndUpdateNonce(base.user, nonce);

        bytes32 structHash = keccak256(
            abi.encode(LOCK_SOURCE_WITH_PERMIT_TYPEHASH, nonce, permitData.fee, sessionAddress)
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), permitData.userSignature);
        if (signer != base.user) revert InvalidSignature();

        uint256 permitAmount = base.amount + permitData.fee;
        IERC20Permit token = IERC20Permit(base.token);
        token.safePermit(
            base.user,
            address(this),
            permitAmount,
            permitData.deadline,
            permitData.v,
            permitData.r,
            permitData.s
        );
        uint256 balanceBefore = IERC20(base.token).balanceOf(address(this));
        IERC20(base.token).safeTransferFrom(base.user, address(this), permitAmount);
        _validateBalanceChange(base.token, balanceBefore, permitAmount);
        collectedFeesByToken[base.token] += permitData.fee;

        _lockSource(base.secretHash, base.token, base.amount, untilTs);
    }

    function lockSourceWithPermit2(
        ICrossChainHTLC.Base calldata base,
        uint256 nonce,
        uint64 untilTs,
        Permit2Data calldata permit2Data,
        address sessionAddress
    ) external onlyRole(ROUTING_MODULE_ROLE) nonReentrant whenNotPaused {
        _validateAndUpdateNonce(base.user, nonce);

        bytes32 structHash = keccak256(
            abi.encode(LOCK_SOURCE_WITH_PERMIT2_TYPEHASH, nonce, permit2Data.fee, sessionAddress)
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), permit2Data.userSignature);
        if (signer != base.user) revert InvalidSignature();

        uint256 permit2Amount = base.amount + permit2Data.fee;
        if (permit2Amount > type(uint160).max) revert Permit2AmountTooHigh();

        IAllowanceTransfer.PermitSingle memory permitSingle = abi.decode(
            permit2Data.permit2Data,
            (IAllowanceTransfer.PermitSingle)
        );

        IAllowanceTransfer(permit2).safePermit2(base.user, permitSingle, permit2Data.permit2Signature);

        uint256 balanceBefore = IERC20(base.token).balanceOf(address(this));
        IAllowanceTransfer(permit2).transferFrom(
            base.user,
            address(this),
            uint160(permit2Amount),
            base.token
        );
        _validateBalanceChange(base.token, balanceBefore, permit2Amount);
        collectedFeesByToken[base.token] += permit2Data.fee;

        _lockSource(base.secretHash, base.token, base.amount, untilTs);
    }

    function lockSourceWithSignature(
        ICrossChainHTLC.Base calldata base,
        uint256 nonce,
        uint64 untilTs,
        SignatureData calldata signatureData,
        address sessionAddress
    ) external onlyRole(ROUTING_MODULE_ROLE) nonReentrant whenNotPaused {
        _validateAndUpdateNonce(base.user, nonce);

        bytes32 structHash = keccak256(
            abi.encode(
                LOCK_SOURCE_WITH_SIGNATURE_TYPEHASH,
                base.amount,
                base.token,
                base.secretHash,
                signatureData.user,
                nonce,
                signatureData.fee,
                sessionAddress
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signatureData.userSignature);
        if (signer != base.user) revert InvalidSignature();
        if (signatureData.user != base.user) revert InvalidSignature();

        uint256 totalAmount = base.amount + signatureData.fee;
        uint256 balanceBefore = IERC20(base.token).balanceOf(address(this));
        IERC20(base.token).safeTransferFrom(base.user, address(this), totalAmount);
        _validateBalanceChange(base.token, balanceBefore, totalAmount);
        collectedFeesByToken[base.token] += signatureData.fee;

        _lockSource(base.secretHash, base.token, base.amount, untilTs);
    }

    function lockDestination(
        bytes32 secretHash,
        address token,
        uint256 amount,
        uint64 untilTs
    ) external onlyRole(ROUTING_MODULE_ROLE) nonReentrant whenNotPaused {
        _lockDestination(secretHash, token, amount, untilTs);
    }

    function transfer(
        bytes32 secretHash,
        address token,
        address to,
        uint256 amount
    ) external onlyRole(ROUTING_MODULE_ROLE) nonReentrant whenNotPaused {
        _transfer(secretHash, token, to, amount);
    }

    function unlock(
        bytes32 secretHash,
        address token,
        uint256 amount
    ) external onlyRole(ROUTING_MODULE_ROLE) nonReentrant whenNotPaused {
        _unlock(secretHash, token, amount);
    }

    function transferForRefund(
        bytes32 secretHash,
        address token,
        address to,
        uint256 amount
    ) external onlyRole(ROUTING_MODULE_ROLE) nonReentrant whenNotPaused {
        _transferForRefund(secretHash, token, to, amount);
    }

    // ========= Internal =========
    function _validateAndUpdateNonce(address user, uint256 nonce) internal {
        if (nonce != lastNonce[user] + 1) revert InvalidNonce();
        lastNonce[user] = nonce;
    }

    function _lockSource(
        bytes32 secretHash,
        address token,
        uint256 amount,
        uint64 untilTs
    ) internal {
        if (!isWhitelisted[token]) revert NotWhitelisted(token);
        lockedAmount[secretHash] = amount;
        totalLockedByToken[token] += amount;
        emit Locked(secretHash, token, amount, untilTs);
    }

    function _lockDestination(
        bytes32 secretHash,
        address token,
        uint256 amount,
        uint64 untilTs
    ) internal {
        if (!isWhitelisted[token]) revert NotWhitelisted(token);

        _validateReserves(token, amount);

        lockedAmount[secretHash] = amount;
        totalLockedByToken[token] += amount;
        emit Locked(secretHash, token, amount, untilTs);
    }

    function _transfer(bytes32 secretHash, address token, address to, uint256 amount) internal {
        _processUnlock(secretHash, token, amount);
        uint256 finalAmount = _applyFee(token, amount);
        _transferWithBalanceCheck(token, to, finalAmount);
        emit TransferredToRecipient(secretHash, token, to, finalAmount);
    }

    function _unlock(bytes32 secretHash, address token, uint256 amount) internal {
        _processUnlock(secretHash, token, amount);
        emit Unlocked(secretHash, token, amount);
    }

    function _transferForRefund(
        bytes32 secretHash,
        address token,
        address to,
        uint256 amount
    ) internal {
        _processUnlock(secretHash, token, amount);
        _transferWithBalanceCheck(token, to, amount);
        emit TransferredToRecipient(secretHash, token, to, amount);
    }

    function _processUnlock(bytes32 secretHash, address token, uint256 amount) internal {
        uint256 locked = lockedAmount[secretHash];
        if (locked == 0) revert LockNotFound();
        if (locked != amount) revert InvalidUnlockAmount();
        lockedAmount[secretHash] = locked - amount;
        totalLockedByToken[token] -= amount;
    }

    function _executeSwap(
        SwapLocal calldata params,
        bytes calldata maintainerSig,
        address sender
    ) internal {
        _validateSwapLocal(params, maintainerSig, sender);
        _executeSwapInternal(params, sender, 0);
    }

    function _executeSwapWithFee(
        SwapLocal calldata params,
        bytes calldata maintainerSig,
        address sender,
        uint256 executionFeeNative
    ) internal {
        _validateSwapLocalWithFee(params, maintainerSig, sender, executionFeeNative);
        _executeSwapInternal(params, sender, executionFeeNative);
    }

    function _validateSwapLocal(
        SwapLocal calldata params,
        bytes calldata maintainerSig,
        address sender
    ) internal view {
        if (params.deadline < block.timestamp) revert DeadlineExpired();
        if (block.chainid != params.chainId) revert InvalidChainId();

        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_LOCAL_TYPEHASH,
                params.amountIn,
                params.tokenIn,
                params.tokenOut,
                params.recipient,
                params.deadline,
                sender,
                params.nonce
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), maintainerSig);
        if (signer != maintainer) revert InvalidSignature();
    }

    function _validateSwapLocalWithFee(
        SwapLocal calldata params,
        bytes calldata maintainerSig,
        address sender,
        uint256 executionFeeNative
    ) internal view {
        if (params.deadline < block.timestamp) revert DeadlineExpired();
        if (block.chainid != params.chainId) revert InvalidChainId();

        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_LOCAL_WITH_FEE_TYPEHASH,
                params.amountIn,
                params.tokenIn,
                params.tokenOut,
                params.recipient,
                params.deadline,
                sender,
                params.nonce,
                executionFeeNative
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), maintainerSig);
        if (signer != maintainer) revert InvalidSignature();
    }

    function _executeSwapInternal(
        SwapLocal calldata params,
        address sender,
        uint256 executionFeeNative
    ) internal {
        if (!isWhitelisted[params.tokenIn]) revert NotWhitelisted(params.tokenIn);
        if (!isWhitelisted[params.tokenOut]) revert NotWhitelisted(params.tokenOut);

        uint256 amountOut = _convertAmount(
            params.amountIn,
            tokenDecimals[params.tokenIn],
            tokenDecimals[params.tokenOut]
        );

        _validateReserves(params.tokenOut, amountOut);
        _validateAndUpdateNonce(sender, params.nonce);

        uint256 finalAmountOut = _applyFee(params.tokenOut, amountOut);

        _transferWithBalanceCheck(params.tokenOut, params.recipient, finalAmountOut);
        emit SwapLocalExecuted(
            sender,
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            finalAmountOut,
            params.recipient,
            executionFeeNative
        );
    }

    function _convertAmount(
        uint256 amountIn,
        uint8 decimalsIn,
        uint8 decimalsOut
    ) internal pure returns (uint256) {
        if (decimalsIn == decimalsOut) {
            return amountIn;
        }

        if (decimalsIn > decimalsOut) {
            return amountIn / (10 ** (decimalsIn - decimalsOut));
        } else {
            return amountIn * (10 ** (decimalsOut - decimalsIn));
        }
    }

    function _validateReserves(address token, uint256 amount) internal view {
        uint256 available = _getAvailableLiquidity(token);
        if (amount > available) revert InsufficientReserves();

        ILiquidityPool.LiquidityThresholds memory thresholds = liquidityThresholds[token];
        uint256 remainingAfterOperation = available - amount;

        if (remainingAfterOperation < thresholds.X) {
            revert InsufficientReserves();
        }

        if (available < thresholds.Y) {
            if (amount > thresholds.Z) {
                revert InsufficientReserves();
            }
        } else {
            if (remainingAfterOperation < (thresholds.Y - thresholds.Z)) {
                revert InsufficientReserves();
            }
        }
    }

    function _applyFee(address token, uint256 amount) internal returns (uint256) {
        if (!feeEnabledByToken[token]) return amount;

        uint256 feeRate = protocolFeeByToken[token];
        if (feeRate == 0) return amount;

        uint256 protocolFee = (amount * feeRate) / FEE_DENOMINATOR;
        if (amount <= protocolFee) revert AmountTooSmallForFee();

        emit ProtocolFeeCollected(token, protocolFee);
        return amount - protocolFee;
    }

    function _validateBalanceChange(
        address token,
        uint256 balanceBefore,
        uint256 expectedAmount
    ) internal view {
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        uint256 actualReceived = balanceAfter - balanceBefore;
        if (actualReceived != expectedAmount) {
            revert FeeOnTransferNotSupported();
        }
    }

    /**
     * @dev Transfer tokens with balance validation. Works with non-standard tokens like USDT on Tron.
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _transferWithBalanceCheck(
        address token,
        address to,
        uint256 amount
    ) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(to, amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        if (balanceBefore - balanceAfter != amount) revert TransferBalanceMismatch();
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}
}
