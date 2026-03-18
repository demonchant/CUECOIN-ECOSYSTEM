# CueCoin (CUECOIN) Ecosystem

![CueCoin Logo](./assets/logo.png)

CueCoin (CUECOIN) is the **native BEP-20 token** of the CueCoin skill-based gaming ecosystem on the **BNB Smart Chain (BSC)**. It powers a self-sustaining, governance-ready ecosystem with play-to-earn games, tournaments, and DAO participation.

---

## Table of Contents

- [Project Overview](#project-overview)  
- [Key Features](#key-features)  
- [Tokenomics](#tokenomics)  
- [Ecosystem Flow](#ecosystem-flow)  
- [Governance](#governance)  
- [Velocity Shield & Whale Guard](#velocity-shield--whale-guard)  
- [Contracts](#contracts)  
- [Deployment & Setup](#deployment--setup)  
- [License](#license)  

---

## Project Overview

CueCoin is designed to provide a **secure, decentralized, and gamified token economy** for skill-based gaming. Its architecture includes:

- Fixed **1 Billion CUECOIN supply** – no minting after deployment  
- **Vortex Tax** for ecosystem sustainability  
- **Auto-LP Engine** for liquidity management  
- **Velocity Shield** for market stability  
- **Whale Guard** to prevent large manipulative trades  
- Governance-ready using **ERC20Votes** for DAO proposals  

---

## Key Features

- **BEP-20 Token**: Fully compatible with BSC ecosystem  
- **Self-sustaining economy**: Play-to-earn, tournaments, DAO funding  
- **Timelocked updates**: Pool & oracle updates have a 48-hour timelock  
- **Anti-whale & Anti-dump protections**: Automatic tax surcharges and shields  
- **Governance-ready**: Delegation and snapshot voting via CueDAO  

---

## Tokenomics

| Feature                  | Allocation |
|---------------------------|------------|
| **Burn**                  | 1.00%      |
| **Auto-LP**               | 1.00%      |
| **P2E Rewards Pool**      | 1.00%      |
| **Tournament Pool**       | 0.50%      |
| **DAO Treasury**          | 0.25%      |
| **Dev Multisig**          | 0.25%      |
| **Total Vortex Tax**      | 4.00%      |

**Additional mechanics:**

- **Velocity Shield:** Activates +4% Auto-LP if TWAP drops >15% in 1 hour and LP ≥ 50 BNB  
- **Whale Guard:** Extra 2% burn on transactions >0.1% of total supply  

---

## Ecosystem Flow

### Mermaid Diagram (GitHub supported)

```mermaid
flowchart LR
    A[User Transfer] --> B[Vortex Tax 4%]
    B --> C[Burn 1% → 0xdead]
    B --> D[Auto-LP 1% → Contract → Liquidity Pool]
    B --> E[P2E Rewards 1% → Rewards Pool]
    B --> F[Tournament 0.5% → Tournament Pool]
    B --> G[DAO 0.25% → DAO Treasury]
    B --> H[Dev Multisig 0.25% → Dev Wallet]

    subgraph Shield
        B2[Velocity Shield +4% LP] 
    end
ASCII Fallback (for non-Mermaid renderers)
User Transfer
     |
   Vortex Tax 4%
   /   |    \    \
Burn  Auto-LP  P2E  Tournament
1%     1%      1%     0.5%
 |      |      |       |
0xdead LP Pool Rewards Tournament Pool
        |
      DAO Treasury 0.25%
      Dev Multisig 0.25%
[Velocity Shield +4% LP]
[Whale Guard +2% Burn]
Auto-LP Engine: Accumulates LP slice and automatically swaps/ adds liquidity when threshold is reached

Tax Distribution: All slices are sent to respective pools automatically

DAO Treasury: Receives rounding dust to ensure no tokens are lost
Governance

CueCoin integrates ERC20Votes and ERC20Permit for governance

Delegation required: Holders must delegate(self) or delegate(other)

Votes are timestamp-aligned (ERC-6372) to ensure historical accuracy

DAO can influence treasury, tournaments, and rewards allocations
Velocity Shield & Whale Guard

Velocity Shield: Prevents large dumps by increasing Auto-LP during 15%+ TWAP drops

Whale Guard: Adds 2% burn on any transaction exceeding 0.1% of total supply

Automatic & Transparent: Both features work without manual intervention
| Contract Name            | Purpose                                |
| ------------------------ | -------------------------------------- |
| `CueCoin.sol`            | Core CUECOIN token contract (BEP-20)   |
| `CueAirdrop.sol`         | Handles token airdrops and user claims |
| `CueBridge.sol`          | Cross-chain token bridge               |
| `CueDAO.sol`             | Governance DAO contract                |
| `CueEscrow.sol`          | Secure escrow for transactions         |
| `CueLiquidityLocker.sol` | Locks LP tokens for security           |
| `CueMarketplace.sol`     | NFT & in-game item marketplace         |
| `CueNFT.sol`             | NFT minting and management             |
| `CueRewardsPool.sol`     | Play-to-earn rewards distribution      |
| `CueReferral.sol`        | Referral system & reward tracking      |
| `CueSitAndGo.sol`        | Sit-and-go tournament logic            |
| `CueTaskRegistry.sol`    | Task tracking for P2E & airdrops       |
| `CueTournament.sol`      | Tournament prize distribution          |
| `CueVesting.sol`         | Token vesting schedules                |
Deployment addresses: To be updated after mainnet deployment
Deployment & Setup
Prerequisites

Make sure you have the following installed:

Node.js
 (v18+ recommended)

Hardhat

npm
 or yarn

Metamask
 or another Web3 wallet

BSC Testnet/Mainnet account with BNB for gas
git clone https://github.com/yourusername/CueCoin-Ecosystem.git
cd CueCoin-Ecosystem/Contracts
    subgraph Whale
        B3[Whale Guard +2% Burn]
    end
