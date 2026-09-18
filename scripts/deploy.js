import hre from "hardhat";

let ethers;

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing environment value ${name}`);
  return value;
}

function addressAt(deployer, nonce) {
  return ethers.getCreateAddress({ from: deployer, nonce });
}

async function deploy(name, args) {
  const factory = await ethers.getContractFactory(name);
  const contract = await factory.deploy(...args);
  await contract.waitForDeployment();
  console.log(`${name}: ${contract.target}`);
  return contract;
}

async function main() {
  ({ ethers } = await hre.network.create());
  const [deployer] = await ethers.getSigners();
  const startNonce = await deployer.getNonce("pending");

  const router = required("PANCAKE_ROUTER");
  const guardian = required("GUARDIAN_MULTISIG");
  const development = required("DEVELOPMENT_MULTISIG");
  const marketing = required("MARKETING_MULTISIG");
  const servers = required("SERVER_MULTISIG");
  const liquidityFunding = required("LIQUIDITY_FUNDING_MULTISIG");
  const tournamentFunding = required("TOURNAMENT_FUNDING_MULTISIG");
  const daoFunding = required("DAO_FUNDING_MULTISIG");
  const priceOracle = required("PRICE_ORACLE");
  const lpOracle = required("LP_ORACLE");
  const oracle0 = required("GAME_ORACLE_0");
  const oracle1 = required("GAME_ORACLE_1");
  const oracle2 = required("GAME_ORACLE_2");
  const complianceOracle = required("COMPLIANCE_ORACLE");
  const layerZeroEndpoint = required("LAYERZERO_ENDPOINT");
  const baseURI = required("NFT_BASE_URI");
  const premiumFee = BigInt(required("PREMIUM_FEE_WEI"));
  const standardFee = BigInt(required("STANDARD_FEE_WEI"));

  const predicted = {
    coin: addressAt(deployer.address, startNonce),
    nft: addressAt(deployer.address, startNonce + 1),
    rewards: addressAt(deployer.address, startNonce + 2),
    escrow: addressAt(deployer.address, startNonce + 3),
    sit: addressAt(deployer.address, startNonce + 4),
    referral: addressAt(deployer.address, startNonce + 5),
    tournament: addressAt(deployer.address, startNonce + 6),
    marketplace: addressAt(deployer.address, startNonce + 7),
    bridge: addressAt(deployer.address, startNonce + 8),
    dao: addressAt(deployer.address, startNonce + 9),
    locker: addressAt(deployer.address, startNonce + 10),
    airdrop: addressAt(deployer.address, startNonce + 11),
    vesting: addressAt(deployer.address, startNonce + 12),
    tasks: addressAt(deployer.address, startNonce + 13)
  };

  const coin = await deploy("CueCoin", [
    router,
    predicted.rewards,
    predicted.tournament,
    predicted.dao,
    development,
    priceOracle,
    lpOracle
  ]);
  const nft = await deploy("CueNFT", [
    coin.target,
    predicted.marketplace,
    predicted.marketplace,
    predicted.tournament,
    predicted.tournament,
    predicted.tournament,
    predicted.airdrop,
    predicted.referral,
    baseURI
  ]);
  const rewards = await deploy("CueRewardsPool", [coin.target, nft.target, guardian, predicted.dao]);
  const escrow = await deploy("CueEscrow", [
    coin.target,
    rewards.target,
    predicted.referral,
    oracle0,
    oracle1,
    oracle2
  ]);
  const sit = await deploy("CueSitAndGo", [coin.target, development, oracle0, oracle1, oracle2]);
  const referral = await deploy("CueReferral", [coin.target, escrow.target, sit.target, nft.target]);
  const tournament = await deploy("CueTournament", [coin.target, nft.target, guardian, predicted.dao]);
  const marketplace = await deploy("CueMarketplace", [coin.target, nft.target, guardian, predicted.dao]);
  const bridge = await deploy("CueBridge", [coin.target, layerZeroEndpoint, guardian, predicted.dao]);
  const dao = await deploy("CueDAO", [
    coin.target,
    guardian,
    coin.target,
    rewards.target,
    escrow.target,
    sit.target,
    marketplace.target,
    bridge.target,
    referral.target
  ]);
  const locker = await deploy("CueLiquidityLocker", [dao.target]);
  const airdrop = await deploy("CueAirdrop", [
    coin.target,
    premiumFee,
    standardFee,
    liquidityFunding,
    development,
    tournamentFunding,
    marketing,
    daoFunding,
    servers,
    oracle0,
    oracle1,
    complianceOracle
  ]);
  const vesting = await deploy("CueVesting", [coin.target, guardian, dao.target]);
  const tasks = await deploy("CueTaskRegistry", [dao.target]);

  const deployed = {
    coin,
    nft,
    rewards,
    escrow,
    sit,
    referral,
    tournament,
    marketplace,
    bridge,
    dao,
    locker,
    airdrop,
    vesting,
    tasks
  };
  for (const [name, expected] of Object.entries(predicted)) {
    if (deployed[name].target.toLowerCase() !== expected.toLowerCase()) {
      throw new Error(`Unexpected ${name} deployment address`);
    }
  }

  await (await sit.setIntegrations(rewards.target, referral.target)).wait();

  const coreOwnedByDao = [coin, rewards, escrow, sit, marketplace, bridge, referral];
  for (const contract of coreOwnedByDao) {
    await (await contract.transferOwnership(dao.target)).wait();
    await (await dao.acceptEcosystemOwnership(contract.target)).wait();
  }

  for (const contract of [nft, tournament, locker, airdrop, vesting, tasks]) {
    await (await contract.transferOwnership(guardian)).wait();
  }

  await (await dao.transferOwnership(guardian)).wait();

  console.log("Deployment complete");
  console.log("The guardian multisig must accept every pending ownership transfer, including the DAO.");
  console.log(`Liquidity locker: ${locker.target}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
