# ![CueCoin Logo](./assets/logo.png) CueCoin Ecosystem

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

CueCoin (CUE) is the **native BEP-20 token** of the CueCoin skill-based gaming ecosystem on the **BNB Smart Chain**. It powers **skill gaming, NFT trading, P2E rewards, tournaments, and governance**. The ecosystem is fully self-sustaining, with automatic liquidity, deflationary mechanics, and timelocked pool and oracle updates for maximum security.

---

## 📈 Ecosystem Flow Diagram

```mermaid
graph LR
    %% ── Core Token & Pools ──
    CUE["CueCoin (CUE)"] --> LP["Auto-LP Engine"]
    CUE --> P2E["CueRewardsPool (P2E Rewards + NFT Bonuses)"]
    CUE --> TOURN["CueTournament (Prize Pool)"]
    CUE --> DAO["CueDAO Treasury (Governance)"]
    CUE --> DEV["Dev Multisig (Operations, Payroll, Marketing)"]
    CUE --> BURN["Burn (0xdead)"]

    %% ── NFT & Marketplace ──
    CUE --> NFT["CueNFT (NFT Mint & Rewards)"]
    NFT --> MARKET["CueMarketplace (NFT Trading)"]

    %% ── Gaming & Skills ──
    CUE --> SNG["CueSitAndGo (Skill Gaming Tournaments)"]
    CUE --> TASK["CueTaskRegistry (Skill Tasks)"]

    %% ── Referral & Incentives ──
    CUE --> REF["CueReferral (Referral Rewards)"]

    %% ── Escrow & Vesting ──
    CUE --> ESC["CueEscrow (Locked Payments)"]
    CUE --> VEST["CueVesting (Team / Investor Vesting)"]

    %% ── Bridge & Airdrop ──
    CUE --> BRIDGE["CueBridge (Cross-Chain Transfers)"]
    CUE --> AIRDROP["CueAirdrop (Token Distribution)"]

    %% ── Flows / interactions
    LP --> BURN
    LP --> MARKET
    P2E --> SNG
    TOURN --> SNG
    REF --> SNG
    VEST --> DEV
    ESC --> DEV
💰 Tokenomics

Name: CueCoin

Symbol: CUECOIN

Chain: BNB Smart Chain (BEP-20)

Total Supply: 1,000,000,000 CUE (1B)

Decimals: 18

No mint function — fixed supply

Deflationary mechanics with burn address 0xdead| Destination  | Tax % | Purpose                                 |
| ------------ | ----- | --------------------------------------- |
| Burn         | 1%    | Permanent deflation                     |
| Auto-LP      | 1%    | Deepens liquidity pool                  |
| P2E Pool     | 1%    | Play-to-earn rewards & NFT bonuses      |
| Tournament   | 0.5%  | Self-funding prize pools                |
| DAO Treasury | 0.25% | Governance treasury                     |
| Dev Multisig | 0.25% | Operations: payroll, servers, marketing |
Velocity Shield (Automatic +4% LP)

Activates if TWAP drops > 15% in 1 hour AND LP depth ≥ 50 BNB

Duration: 4 hours

Tax rises from 4% → 8%

Fully automatic, cannot be triggered manually

Whale Guard (+2% burn)
🏗️ Contracts Overview
| Contract               | Purpose                                |
| ---------------------- | -------------------------------------- |
| CueCoin.sol            | Core token with tax logic & governance |
| CueNFT.sol             | NFT minting & rewards                  |
| CueMarketplace.sol     | NFT trading marketplace                |
| CueSitAndGo.sol        | Skill-based gaming tournaments         |
| CueTaskRegistry.sol    | Skill task management for rewards      |
| CueReferral.sol        | Referral rewards system                |
| CueEscrow.sol          | Locked payments & escrow               |
| CueVesting.sol         | Team/investor vesting                  |
| CueBridge.sol          | Cross-chain token bridge               |
| CueAirdrop.sol         | Token airdrop & distribution           |
| CueRewardsPool.sol     | P2E reward pool                        |
| CueTournament.sol      | Tournament prize pool                  |
| CueDAO.sol             | Governance treasury                    |
| CueLiquidityLocker.sol | LP token locking & timelocks           |

Transactions > 0.1% of total supply (~1,000,000 CUE) pay extra 2% to burn

Exempt: vesting, airdrops, ecosystem contracts🚀 Deployment Setup

Install dependencies:

npm install

Configure hardhat.config.js or truffle-config.js with BSC mainnet/testnet RPC.

Deploy CueCoin first:

npx hardhat run scripts/deployCueCoin.js --network bscTestnet

Deploy all pools & ecosystem contracts (replace addresses with CueCoin address):

npx hardhat run scripts/deployEcosystem.js --network bscTestnet

Configure oracles, timelocks, and trading:

Set priceOracle & lpOracle

Enable trading: cueCoin.enableTrading()

Queue pool & oracle updates via timelock

⚡ Features

Automatic liquidity provision & burn mechanism

Play-to-Earn reward system with NFT bonuses

Skill-based gaming tournaments

Referral incentives for players

Vesting & escrow for team & investors

DAO governance with ERC20Votes integration

Velocity Shield & Whale Guard for anti-dump protection

Cross-chain bridge & airdrop system for distribution

📝 License

This project is licensed under the MIT License — see the LICENSE
 file for details.
