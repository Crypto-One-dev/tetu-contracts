import chai from "chai";
import chaiAsPromised from "chai-as-promised";
import {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";
import {ethers} from "hardhat";
import {TimeUtils} from "../TimeUtils";
import {
  Announcer,
  AutoRewarder,
  Bookkeeper,
  Controller,
  PriceCalculator,
  RewardCalculator,
  SmartVault
} from "../../typechain";
import {DeployerUtils} from "../../scripts/deploy/DeployerUtils";
import {Addresses} from "../../addresses";
import {MintHelperUtils} from "../MintHelperUtils";
import {BigNumber, utils} from "ethers";
import {CoreAddresses} from "../../scripts/models/CoreAddresses";
import {TokenUtils} from "../TokenUtils";
import {MaticAddresses} from "../MaticAddresses";

const {expect} = chai;
chai.use(chaiAsPromised);

const vaultsSet = new Set<string>([
  '0x0ed08c9A2EFa93C4bF3C8878e61D2B6ceD89E9d7',
  '0x6f2fb669B52e4ED21a019e9db197F27f4B88eBf9',
  '0x57205cC741f8787a5195B2126607ac505E11B650'
]);

describe("Reward calculator tests", function () {
  let snapshot: string;
  let snapshotForEach: string;
  let gov: SignerWithAddress;
  let priceCalculator: PriceCalculator;
  let rewardCalculator: RewardCalculator;
  let rewarder: AutoRewarder;
  let bookkeeper: Bookkeeper;
  let controller: Controller;
  let announcer: Announcer;
  let coreAddresses: CoreAddresses;

  before(async function () {
    this.timeout(12000000000);
    snapshot = await TimeUtils.snapshot();
    gov = await DeployerUtils.impersonate();

    coreAddresses = Addresses.CORE.get('matic') as CoreAddresses;
    const controllerAdr = coreAddresses.controller;
    const announcerAdr = coreAddresses.announcer;
    const bookkeeperAdr = coreAddresses.bookkeeper;

    bookkeeper = await DeployerUtils.connectInterface(gov, 'Bookkeeper', bookkeeperAdr) as Bookkeeper;
    controller = await DeployerUtils.connectInterface(gov, 'Controller', controllerAdr) as Controller;
    announcer = await DeployerUtils.connectInterface(gov, 'Announcer', announcerAdr) as Announcer;

    priceCalculator = (await DeployerUtils.deployPriceCalculatorMatic(gov, controllerAdr))[0] as PriceCalculator;
    rewardCalculator = (await DeployerUtils.deployRewardCalculator(gov, controllerAdr, priceCalculator.address))[0] as RewardCalculator;
    rewarder = await DeployerUtils.deployAutoRewarder(gov, controllerAdr, rewardCalculator.address);

    await rewarder.setNetworkRatio(utils.parseUnits('0.231'));
    await rewarder.setRewardPerDay(utils.parseUnits('1000'));


    // await rewardCalculator.set
    await controller.setRewardDistribution([rewarder.address], true);
  });

  after(async function () {
    await TimeUtils.rollback(snapshot);
  });

  beforeEach(async function () {
    snapshotForEach = await TimeUtils.snapshot();
  });

  afterEach(async function () {
    await TimeUtils.rollback(snapshotForEach);
  });

  it.skip("distribute to all", async () => {
    const rewardsPerDay = await rewarder.rewardsPerDay();
    console.log('rewards per day', utils.formatUnits(rewardsPerDay));

    await MintHelperUtils.mintAll(controller, announcer, rewarder.address);

    const bal = await TokenUtils.balanceOf(coreAddresses.rewardToken, rewarder.address);
    console.log('minted', utils.formatUnits(bal));

    const vaults = await bookkeeper.vaults();
    console.log('vaults', vaults.length)

    const step = 2;

    for (let i = 0; i < vaults.length; i = i + step) {
      console.log('collect', i, i + step);
      console.log('vaults.slice(i, i + step)', vaults.slice(i, i + step))
      try {
        await rewarder.collectAndStoreInfo(vaults.slice(i, i + step));
      } catch (e) {
        console.log('error collect', e);
      }

    }

    console.log('totalStrategyRewards', utils.formatUnits(await rewarder.totalStrategyRewards()));

    for (let i = 0; i < vaults.length; i = i + step) {
      console.log('distribute', i, i + step);
      await distribute(rewarder, step);
    }

    const distributed = await rewarder.distributed();
    expect(distributed).is.eq(0);
  });

  it("distribute to vaults set", async () => {
    const rewardsPerDay = await rewarder.rewardsPerDay();
    console.log('rewards per day', utils.formatUnits(rewardsPerDay));

    await MintHelperUtils.mintAll(controller, announcer, rewarder.address);

    const bal = await TokenUtils.balanceOf(coreAddresses.rewardToken, rewarder.address);
    console.log('minted', utils.formatUnits(bal));

    const vaults = Array.from(vaultsSet.keys());
    console.log('vaults', vaults.length)

    const step = 2;

    for (let i = 0; i < vaults.length; i = i + step) {
      console.log('collect', i, i + step);
      console.log('vaults.slice(i, i + step)', vaults.slice(i, i + step))
      try {
        await rewarder.collectAndStoreInfo(vaults.slice(i, i + step));
      } catch (e) {
        console.log('error collect', e);
      }

    }

    console.log('totalStrategyRewards', utils.formatUnits(await rewarder.totalStrategyRewards()));

    for (let i = 0; i < vaults.length; i = i + step) {
      console.log('distribute', i, i + step);
      await distribute(rewarder, step);
    }

    let distributedSum = BigNumber.from(0)
    let strategyRewardsSum = BigNumber.from(0)
    for (const vault of vaults) {
      const distributed = await rewarder.lastDistributedAmount(vault)
      const info = await rewarder.lastInfo(vault)
      strategyRewardsSum = strategyRewardsSum.add(info.strategyRewardsUsd);
      distributedSum = distributedSum.add(distributed)
      console.log('distributed', utils.formatUnits(distributed));
      console.log('info.strategyRewardsUsd', utils.formatUnits(info.strategyRewardsUsd));
    }

    console.log('distributed sum', utils.formatUnits(distributedSum));
    console.log('strategyRewardsSum', utils.formatUnits(strategyRewardsSum));

    for (const vault of vaults) {
      const info = await rewarder.lastInfo(vault)
      const distributed = +utils.formatUnits(await rewarder.lastDistributedAmount(vault))
      const toDistribute = +utils.formatUnits(rewardsPerDay) * (
          +utils.formatUnits(info.strategyRewardsUsd) / +utils.formatUnits(strategyRewardsSum)
      )
      console.log('toDistribute', toDistribute)
      console.log('distributed', distributed)
      expect(distributed).approximately(toDistribute, toDistribute * 0.0001);
    }
    expect(+utils.formatUnits(distributedSum)).is.approximately(+utils.formatUnits(await rewarder.rewardsPerDay()), 0.00001);

    expect(await rewarder.distributed()).is.eq(0);

    await expect(rewarder.distribute(1)).rejectedWith('AR: Too early');

    await TimeUtils.advanceBlocksOnTs(60 * 60 * 24);

    await expect(rewarder.distribute(1)).rejectedWith('AR: Info too old');

    for (let i = 0; i < vaults.length; i = i + step) {
      console.log('collect', i, i + step);
      console.log('vaults.slice(i, i + step)', vaults.slice(i, i + step))
      try {
        await rewarder.collectAndStoreInfo(vaults.slice(i, i + step));
      } catch (e) {
        console.log('error collect', e);
      }

    }

    for (let i = 0; i < vaults.length; i = i + step) {
      console.log('distribute', i, i + step);
      await distribute(rewarder, step);
    }

    expect(await rewarder.distributed()).is.eq(0);

    distributedSum = BigNumber.from(0)
    for (const vault of vaults) {
      const distributed = await rewarder.lastDistributedAmount(vault)
      distributedSum = distributedSum.add(distributed)
      console.log('distributed', utils.formatUnits(distributed));
    }

    console.log('distributed sum', utils.formatUnits(distributedSum));
    expect(+utils.formatUnits(distributedSum)).is.approximately(+utils.formatUnits(await rewarder.rewardsPerDay()), 0.00001);
  });

});

async function distribute(rewarder: AutoRewarder, count: number) {
  const xTetuVault = await DeployerUtils.connectInterface(rewarder.signer as SignerWithAddress, 'SmartVault', MaticAddresses.xTETU) as SmartVault
  const vaultsSize = (await rewarder.vaultsSize()).toNumber();
  // console.log('vaultsSize', vaultsSize);
  const currentId = (await rewarder.lastDistributedId()).toNumber();
  const to = Math.min(vaultsSize, currentId + count);
  // console.log('currentId', currentId, to);
  const data = [];
  for (let i = currentId; i < to; i++) {
    console.log('i', i)
    const vault = await rewarder.vaults(i);
    // console.log('vault', i, vault);
    data.push({
      vault,
      bal: await xTetuVault.underlyingBalanceWithInvestmentForHolder(vault)
    });
  }
  // console.log('DISTRIBUTE', count);
  await rewarder.distribute(count);

  for (const d of data) {
    const vault = d.vault;
    // console.log('vault', vault);
    const distributed = await rewarder.lastDistributedAmount(vault);
    console.log('distributed', utils.formatUnits(distributed))
    const curBal = await xTetuVault.underlyingBalanceWithInvestmentForHolder(vault);
    expect(+utils.formatUnits(curBal.sub(d.bal))).is.approximately(+utils.formatUnits(distributed), 0.00001);
  }
}