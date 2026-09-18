# CueCoin Ecosystem

CueCoin is a fixed supply gaming economy for BNB Smart Chain. Its token symbol is `CUE`. The system combines taxed token transfers, player wagers, tournaments, rewards, achievements, referrals, governance, vesting, liquidity locks, an airdrop, and LayerZero based bridging.

`CueStrike` is the planned first crown jewel of the ecosystem: a competitive mobile snooker game built around practice, fair matchmaking, direct challenges, tournaments, achievements, and transparent CUE settlement. Chess, draughts, and additional skill based games are intended to follow after CueStrike establishes the shared player and settlement foundation. The games are future products and are not included in this smart contract repository today.

This repository is source code, tests, and deployment tooling. It is not a promise of profit. Do not deploy it with public funds until an independent audit, a testnet launch, operational rehearsals, and legal review are complete.

The repository root also contains the public airdrop portal. It explains both claim paths, reads live fees and status from `CueAirdrop`, displays active tasks from `CueTaskRegistry`, accepts Merkle proofs, records Terms of Service acceptance, submits claims, and shows standard unlock progress. Claims remain disabled while deployment addresses are blank in `config.js`.

## What the ecosystem does

`CueCoin` creates one billion CUE once. It cannot mint more. Normal taxable transfers route value to six destinations: token burn, automatic liquidity, player rewards, tournament funding, DAO treasury, and development operations. System contracts can be excluded from this tax so internal payouts are not taxed twice.

`CueEscrow` holds two player wagers. An oracle certificate settles ordinary matches. Wagers above the high value threshold need two distinct oracles that sign the exact same result. Completed matches send protocol fees to burn and rewards, pay the winner, request an NFT bonus, and update referral volume.

`CueSitAndGo` opens fixed sixteen player queues. Two distinct oracle signatures settle each game. The first and second players receive prizes, part of the pot burns, and part funds operations. The winner can receive a player reward and both finalists are reported to the referral system.

`CueTournament` operates brackets from eight to one hundred twenty eight players. Entry fees and an explicitly allocated share of the token tax form the prize pot. Signed match results advance each round. A stalled tournament expires after the progress timeout and players can pull refunds. Monthly, regional, and world winners can receive achievement NFTs.

`CueRewardsPool` releases a controlled reward budget over time and pays approved game contracts. NFT ownership can increase player rewards. A depletion guard halves the release rate once per depletion event instead of repeatedly cutting it on every interaction.

`CueNFT` contains Common, Rare, Epic, Legendary, Genesis, and referral badge tiers. Supply caps are enforced in bytecode. Rare and Epic wallet caps also apply to secondary transfers. Legendary and Genesis tokens are soulbound. Marketplace sales update the NFT floor data. Wallet token lists and Hall of Fame records are indexed from standard events to keep the contract deployable within the EVM size limit.

`CueMarketplace` supports fixed price, English auction, Dutch auction, and bundle sales paid only in CUE. It escrows listed NFTs, uses pull refunds, blocks repeat counterparty wash trades, splits bundle royalties among every original minter, burns part of each royalty, and routes the adjustable platform fee to DAO. Royalties are enforced inside this marketplace. The NFT does not advertise external ERC2981 royalties because a plain ERC20 royalty payment cannot identify the sold token reliably.

`CueReferral` links a referee to one referrer. The first completed match accrues a tier based reward and may pay a referee bonus. Rewards are removed from the pool only when paid, preventing the former double debit. Diamond revenue uses a small share of actual protocol fees rather than gross wager volume.

`CueDAO` uses timestamp checkpoints from `ERC20Votes`. A proposal snapshots the last completed timestamp, so token movements after creation do not add voting power. Proposals require a refundable or slashable CUE deposit, vote for seventy two hours, and wait forty eight hours before execution. Tax rates are intentionally immutable. Governance can update contract integrations through functions that match the deployed interfaces.

`CueAirdrop` supports premium and standard Merkle claims. Premium supply can reach one hundred million CUE. Standard supply can reach four hundred million CUE. Maximum liability is therefore five hundred million CUE. Claims must remain closed while a Merkle root update waits through its timelock. BNB fee destinations must be treasury multisigs that can receive BNB. Liquidity funding is sent to a liquidity operations multisig, which creates liquidity and then deposits the resulting LP asset into `CueLiquidityLocker`.

`CueLiquidityLocker` holds ERC20 LP tokens or ERC721 liquidity positions. No one can unlock before the timestamp. After the timestamp, anyone may trigger delivery to the recorded recipient, so an inactive DAO cannot strand matured liquidity.

`CueVesting` manages funded token schedules and protects beneficiary obligations from recovery.

`CueTaskRegistry` stores airdrop task metadata. The twelve sample tasks deploy inactive because several identifiers depend on real launch accounts and snapshots. Governance must update and review each task before activation.

`CueBridge` locks CUE on BNB Smart Chain and releases it when trusted LayerZero messages return. Peer changes wait forty eight hours. Inbound processing supports pause and replay protection. `CueOFT` is the destination chain token. It mints after a trusted inbound message and burns when returning to another trusted chain. Wrapped supply should always be matched by locked BNB Smart Chain reserve.

## Token flow

1. Players acquire CUE and optionally delegate voting power.
2. Transfers grow liquidity, rewards, tournaments, DAO, operations, and burn balances.
3. Games lock wagers in escrow contracts and settle only from valid oracle consensus.
4. Rewards and NFTs improve retention without increasing token supply.
5. Marketplace activity routes value to creators, burn, and governance.
6. Governance controls approved integrations after voting and delay.
7. Bridge adapters move representation between chains while preserving the fixed global supply model.

## Security model

The contracts use OpenZeppelin 5.4.0 and Solidity 0.8.24. Important controls include fixed supply, checked arithmetic, pull refunds, reentrancy guards, oracle expiry, exact certificate binding, replay protection, daily exposure caps, governance delay, ownership handover, immutable tax rates, token recovery guards, and permissionless maturity actions.

Oracle keys must be held by independent systems. Guardian and treasury roles should be separate multisigs. The deployer key should not retain ownership after setup. No private key belongs in this repository.

## Build and test

Install Node.js, then run:

```text
npm install
npm run compile
npm test
```

To preview the airdrop portal locally, run `npm run web` and open `http://127.0.0.1:4173`. Before publishing it, set the verified contract addresses, proof service URL, and legally reviewed terms URL in `config.js`.

Dependencies are pinned in `package.json` and `package-lock.json`. The optimizer uses one run because `CueNFT` is close to the EVM deployment size ceiling. Do not change compiler settings without checking deployed bytecode size again.

## Deployment

Copy `.env.example` into your private secret manager or local environment. Never commit filled secrets.

Testnet deployment:

```text
npx hardhat run scripts/deploy.js --network bsc_testnet
```

Mainnet deployment:

```text
npx hardhat run scripts/deploy.js --network bsc
```

The script predicts contract addresses before deployment to break constructor dependency cycles. It verifies actual deployment order through transaction nonces, wires integrations, and transfers core ownership to DAO. Multisig nominees must accept their pending ownership after deployment.

Before enabling trading:

1. Verify every contract and constructor argument on the block explorer.
2. Fund rewards, airdrop, vesting, tournament reserve, and DAO according to the published allocation.
3. Configure and independently test all oracle signers.
4. Configure bridge peers on both sides and wait through each peer delay.
5. Replace and review every inactive sample task before activation.
6. Create liquidity, lock the LP asset for at least eighteen months, and verify the lock.
7. Run full testnet matches, cancellations, refunds, proposals, marketplace sales, and bridge returns.
8. Obtain an independent security audit and resolve every finding.
9. Transfer or accept every intended ownership role.
10. Enable trading only after monitoring and emergency procedures are live.

## Product direction

The strongest future for CueCoin is as useful game infrastructure, not as a token that depends on marketing alone. A credible launch should begin with a small playable community, measurable match volume, reliable settlement, transparent reserves, and visible governance. If players return because the competitive game is enjoyable, the rewards, NFTs, tournaments, referrals, and marketplace can reinforce one another.

The main risks are operational rather than purely technical: acquiring players, preventing oracle collusion, funding liquidity, maintaining legal compliance, supporting users, and keeping reward emissions below real demand. Cross chain expansion should follow proven BNB Smart Chain usage, not precede it. Marketing can amplify a working product, but it cannot substitute for retention, trust, or liquidity.

## License

MIT. See `LICENSE`.
