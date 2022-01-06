import {ethers} from 'hardhat';
import {BigNumber, Contract} from 'ethers';
import {expect} from 'chai';
import {SignerWithAddress} from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';
import {
  IController,
  IERC20,
  IVault,
  MockAssetManagedPool,
  TetuVaultAssetManager
} from "../../../../typechain";
import {BytesLike} from "@ethersproject/bytes";
import {DeployerUtils} from "../../../../scripts/deploy/DeployerUtils";
import {bn, fp} from "./helpers/numbers";
import {encodeInvestmentConfig} from "./helpers/rebalance";
import {encodeJoin, encodeExit} from "./helpers/mockPool";
import {MAX_UINT256, PoolSpecialization} from "./helpers/constants";
import {TimeUtils} from "../../../TimeUtils";
import {config as dotEnvConfig} from "dotenv";
import {MaticAddresses} from "../../../../scripts/addresses/MaticAddresses";
import {TokenUtils} from "../../../TokenUtils";

dotEnvConfig();
// tslint:disable-next-line:no-var-requires
const argv = require('yargs/yargs')()
.env('TETU')
.options({
  disableStrategyTests: {
    type: "boolean",
    default: false,
  }
}).argv;

const TETU_CONTROLLER = '0x6678814c273d5088114B6E40cC49C8DB04F9bC29';
const BAL_VAULT = '0xBA12222222228d8Ba445958a75a0704d566BF2C8';

const setup = async () => {
  const [signer, investor, other] = (await ethers.getSigners());

  // Connect to balancer vault
  let vault = await ethers.getContractAt(
    "IVault", BAL_VAULT) as IVault;

  // Deploy Pool
  const pool = await DeployerUtils.deployContract(
    signer, "MockAssetManagedPool", vault.address, PoolSpecialization.GeneralPool) as MockAssetManagedPool;
  const poolId = await pool.getPoolId();

  // Deploy Asset manager
  const assetManager = await DeployerUtils.deployContract(signer,
    'TetuVaultAssetManager', vault.address, poolId, MaticAddresses.USDC_TOKEN) as TetuVaultAssetManager;

  // add AM to whitelist
  const gov = await DeployerUtils.impersonate();
  const vaultController = await DeployerUtils.connectInterface(gov, 'IController', TETU_CONTROLLER) as IController
  await vaultController.addToWhiteList(assetManager.address);

  // Assign assetManager to the USDC_TOKEN token, and other to the other token
  const assetManagers = [assetManager.address, other.address];
  const tokensAddresses = [MaticAddresses.USDC_TOKEN, MaticAddresses.WMATIC_TOKEN]

  await pool.registerTokens(tokensAddresses, assetManagers);

  const config = {
    targetPercentage: fp(0.5),
    upperCriticalPercentage: fp(0.6),
    lowerCriticalPercentage: fp(0.4),
  };

  await pool.setAssetManagerPoolConfig(assetManager.address, encodeInvestmentConfig(config));


  // get tokens to invest
  await TokenUtils.getToken(MaticAddresses.WMATIC_TOKEN, investor.address, bn(1000000));
  await TokenUtils.approve(MaticAddresses.WMATIC_TOKEN, investor, vault.address, "1000000")
  await TokenUtils.getToken(MaticAddresses.USDC_TOKEN, investor.address, bn(1000000));
  await TokenUtils.approve(MaticAddresses.USDC_TOKEN, investor, vault.address, "1000000")
  vault = await ethers.getContractAt("IVault", BAL_VAULT, investor) as IVault;

  const ud = encodeJoin(
    tokensAddresses.map(() => BigNumber.from(1000000)),
    tokensAddresses.map(() => 0)
  );

  await vault.joinPool(poolId, investor.address, investor.address, {
    assets: tokensAddresses,
    maxAmountsIn: tokensAddresses.map(() => MAX_UINT256),
    fromInternalBalance: false,
    userData: ud,
  });

  console.log('############## Preparations completed ##################');

  return {
    data: {
      poolId,
    },
    contracts: {
      assetManager,
      pool,
      vault,
    },
  };
};

describe('Tetu Asset manager', function () {
  let vault: Contract;
  let assetManager: Contract;
  let pool: Contract;
  let poolId: BytesLike;
  let investor: SignerWithAddress;
  let other: SignerWithAddress;

  if (argv.disableStrategyTests) {
    return;
  }

  before('deploy base contracts', async () => {
    [, investor, other] = await ethers.getSigners();
  });

  beforeEach('set up asset manager', async () => {
    const {contracts, data} = await setup();

    assetManager = contracts.assetManager;
    vault = contracts.vault;
    pool = contracts.pool;
    poolId = data.poolId;
  });

  describe('claimRewards', () => {


    it('AM should use assets in the Tetu Vault earn xTetu rewards', async () => {
      await assetManager.rebalance(poolId, false);
      const xTetuToken = await ethers.getContractAt("IERC20", MaticAddresses.xTETU, investor) as IERC20;
      const sevenDays = 7 * 24 * 60 * 60;
      await TimeUtils.advanceBlocksOnTs(sevenDays);
      await assetManager.claimRewards();
      const xTetuEarned = await xTetuToken.balanceOf(pool.address);
      console.log("xTetu token earned: ", xTetuEarned.toString());
      expect(xTetuEarned).to.be.gt(0, "We should earn rewards from lending protocol")

    });

    it('AM should rebalanced properly after withdraw funds.', async () => {
      await assetManager.rebalance(poolId, false);
      const poolTokens = [MaticAddresses.USDC_TOKEN, MaticAddresses.WMATIC_TOKEN]
      const usdcToken = await ethers.getContractAt("IERC20", MaticAddresses.USDC_TOKEN, investor) as IERC20;
      const usdcBefore = await usdcToken.balanceOf(investor.address);

      await vault.connect(investor).exitPool(poolId, investor.address, investor.address, {
        assets: poolTokens,
        minAmountsOut: Array(poolTokens.length).fill(0),
        toInternalBalance: false,
        userData: encodeExit([BigNumber.from(500000), BigNumber.from(0)], Array(poolTokens.length).fill(0)),
      });
      const usdcBal = await usdcToken.balanceOf(investor.address);
      expect(usdcBefore.add(BigNumber.from(500000))).to.be.eq(usdcBal);
      await assetManager.rebalance(poolId, false);

      await vault.connect(investor).exitPool(poolId, investor.address, investor.address, {
        assets: poolTokens,
        minAmountsOut: Array(poolTokens.length).fill(0),
        toInternalBalance: false,
        userData: encodeExit([BigNumber.from(250000), BigNumber.from(0)], Array(poolTokens.length).fill(0)),
      });

      const usdcBal1 = await usdcToken.balanceOf(investor.address);
      expect(usdcBal.add(BigNumber.from(250000))).to.be.eq(usdcBal1);

    });

    it('AM should return error when withdraw more funds than in vault', async () => {
      await assetManager.rebalance(poolId, false);
      // after re balance 50 usdc should be invested by AM and 50 usdc available in the vault
      const poolTokens = [MaticAddresses.USDC_TOKEN, MaticAddresses.WMATIC_TOKEN]

      await expect(vault.connect(investor).exitPool(poolId, investor.address, investor.address, {
        assets: poolTokens,
        minAmountsOut: Array(poolTokens.length).fill(0),
        toInternalBalance: false,
        userData: encodeExit([BigNumber.from(500001), BigNumber.from(0)], Array(poolTokens.length).fill(0)),
      })).to.be.revertedWith('BAL#001');
    });
  });
});
