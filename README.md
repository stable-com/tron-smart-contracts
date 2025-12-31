# Tron Contracts - HTLC Cross-Chain Swap Protocol

A production-ready cross-chain token swap protocol using Hash Time Lock Contracts (HTLC) and protocol-owned liquidity pools. Enables atomic single-chain and cross-chain token swaps with built-in AML compliance and multiple gasless transaction options for the Tron blockchain.

## Quick Start

### Installation
```bash
npm install
```

### Compilation
```bash
npm run compile
# or
tronbox compile
```

### Testing
```bash
npm test
# or
tronbox test
```

### Deployment
```bash
# Deploy to Shasta testnet
tronbox migrate --network shasta

# Deploy to Mainnet
tronbox migrate --network mainnet
```



## Core Contracts

### CrossChainHTLC.sol
Handles atomic cross-chain swaps using Hash Time Lock mechanism. Supports multiple gasless transaction methods (Permit, Permit2, signature-based) and integrates with LiquidityPool for instant swaps.

**Key Features:**
- Atomic cross-chain swaps with secret hash validation
- EIP-712 typed signatures for AML compliance
- Gasless transactions (Permit, Permit2, signature-based)
- Role-based access control (5 roles)
- Upgradeable (UUPS proxy pattern)

### LiquidityPool.sol
Protocol-owned liquidity pool for 1:1 token swaps.

**Key Features:**
- Single-chain and cross-chain swap support
- X/Y/Z liquidity thresholds to prevent pool depletion
- Per-token configurable fees
- Gasless transaction options
- Token whitelisting

## Configuration

Create `.env` file in the root directory and configure:

```bash
# Private Keys (without 0x prefix)
PRIVATE_KEY_SHASTA=your_shasta_testnet_private_key
PRIVATE_KEY_MAINNET=your_mainnet_private_key

# TronGrid API Key (optional, for higher rate limits)
TRONGRID_API_KEY=your_trongrid_api_key
```

### Networks

- **Shasta Testnet**: Test network for development
  - Explorer: https://shasta.tronscan.org
  - Faucet: https://www.trongrid.io/shasta

- **Mainnet**: Tron production network
  - Explorer: https://tronscan.org

### Contract Verification

Verify deployed contracts on TronScan:

```bash
# Automatic verification (if supported by TronScan API)
npm run verify:tronscan

# Manual verification using flattened source
npm run flatten
# Then upload the flattened files to TronScan manually
```

## Tron-Specific Considerations

### Address Format
- Tron uses base58check encoded addresses (e.g., `TXYZoPBi...`)
- Internally converted to hex format for smart contracts
- Use TronWeb utilities for address conversion

### Resource Model
Unlike Ethereum's gas model, Tron uses:
- **Energy**: For smart contract execution (similar to gas)
- **Bandwidth**: For transaction size
- Both can be obtained by freezing TRX or paying fees

### Token Standards
- **TRC-20**: Fungible tokens (similar to ERC-20)
- Native USDT on Tron is TRC-20

### Fee Limit
- Set `feeLimit` in tronbox.js for transaction execution
- Recommended: 1000-5000 TRX for complex contract calls
- Unused fees are returned to the sender

