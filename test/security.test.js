import { expect } from "chai";
import hre from "hardhat";

const { ethers } = await hre.network.create();

describe("CueCoin security repairs", function () {
  it("creates a DAO proposal from a valid past timestamp snapshot", async function () {
    const [owner] = await ethers.getSigners();
    const router = await (await ethers.getContractFactory("MockRouter")).deploy();
    const coin = await (await ethers.getContractFactory("CueCoin")).deploy(
      router.target,
      owner.address,
      owner.address,
      owner.address,
      owner.address,
      owner.address,
      owner.address
    );
    await coin.delegate(owner.address);
    const dao = await (await ethers.getContractFactory("CueDAO")).deploy(
      coin.target,
      owner.address,
      coin.target,
      owner.address,
      owner.address,
      owner.address,
      owner.address,
      owner.address,
      owner.address
    );
    await coin.approve(dao.target, ethers.parseEther("500000"));
    await expect(dao.propose(0, "Test proposal", "0x", ethers.ZeroAddress))
      .to.emit(dao, "ProposalCreated");
  });

  it("enforces rare wallet caps on secondary transfers", async function () {
    const [owner, alice, bob] = await ethers.getSigners();
    const token = await (await ethers.getContractFactory("MockERC20")).deploy();
    const nft = await (await ethers.getContractFactory("CueNFT")).deploy(
      token.target,
      owner.address,
      owner.address,
      owner.address,
      owner.address,
      owner.address,
      owner.address,
      owner.address,
      "ipfs://cuecoin/"
    );
    const root = ethers.keccak256(ethers.toUtf8Bytes("match history"));
    await nft.mintRare(alice.address, 10, root);
    await nft.mintRare(bob.address, 10, root);
    await expect(nft.connect(bob).transferFrom(bob.address, alice.address, 2))
      .to.be.revertedWith("CueNFT: recipient rare cap reached");
  });

  it("keeps an accrued referral reward in the pool until it is claimed", async function () {
    const [owner, referrer, referee] = await ethers.getSigners();
    const token = await (await ethers.getContractFactory("MockERC20")).deploy();
    const nft = await (await ethers.getContractFactory("MockCueNFTReader")).deploy();
    const referral = await (await ethers.getContractFactory("CueReferral")).deploy(
      token.target,
      owner.address,
      ethers.ZeroAddress,
      nft.target
    );

    await token.transfer(referral.target, ethers.parseEther("1000"));
    await referral.notifyRefill(ethers.parseEther("1000"));
    await referral.recordMatchCompletion(referrer.address);
    await referral.connect(referee).registerReferral(referrer.address);
    await referral.recordMatchCompletion(referee.address);

    expect(await referral.rewardPool()).to.equal(ethers.parseEther("990"));
    await referral.connect(referrer).claimRewards();
    expect(await referral.rewardPool()).to.equal(ethers.parseEther("965"));
  });

  it("requires both high value escrow signatures to approve the same certificate", async function () {
    const [owner, playerB, oracleA, oracleB, oracleC] = await ethers.getSigners();
    const token = await (await ethers.getContractFactory("MockERC20")).deploy();
    const rewards = await (await ethers.getContractFactory("MockRewardsPool")).deploy();
    const escrow = await (await ethers.getContractFactory("CueEscrow")).deploy(
      token.target,
      rewards.target,
      ethers.ZeroAddress,
      oracleA.address,
      oracleB.address,
      oracleC.address
    );

    const wager = ethers.parseEther("10001");
    await token.transfer(playerB.address, wager);
    await token.approve(escrow.target, wager);
    await token.connect(playerB).approve(escrow.target, wager);
    const receipt = await (await escrow.createMatch(wager, 5)).wait();
    const created = receipt.logs
      .map((log) => { try { return escrow.interface.parseLog(log); } catch { return null; } })
      .find((entry) => entry && entry.name === "MatchCreated");
    const matchId = created.args.matchId;
    await escrow.connect(playerB).joinMatch(matchId);

    const network = await ethers.provider.getNetwork();
    const domain = {
      name: "CueEscrow",
      version: "3",
      chainId: network.chainId,
      verifyingContract: escrow.target
    };
    const types = {
      VictoryCertificate: [
        { name: "matchId", type: "bytes32" },
        { name: "winner", type: "address" },
        { name: "nftBonusWei", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "expiry", type: "uint256" }
      ]
    };
    const now = (await ethers.provider.getBlock("latest")).timestamp;
    const first = {
      matchId,
      winner: owner.address,
      nftBonusWei: 0,
      nonce: 77,
      expiry: now + 300
    };
    await escrow.submitHighValueSignature(
      matchId,
      first.winner,
      first.nftBonusWei,
      first.nonce,
      first.expiry,
      await oracleA.signTypedData(domain, types, first)
    );

    const changed = { ...first, winner: playerB.address };
    await expect(
      escrow.claimVictoryHighValue(
        matchId,
        changed.winner,
        changed.nftBonusWei,
        changed.nonce,
        changed.expiry,
        await oracleB.signTypedData(domain, types, changed)
      )
    ).to.be.revertedWith("CueEscrow: certificate differs from first signature");
  });
});
