import {SpecificStrategyTest} from "../../SpecificStrategyTest";
import {BigNumber} from "ethers";
import {TokenUtils} from "../../../TokenUtils";
import {IStrategy, SmartVault, StrategyMaiBal} from "../../../../typechain";
import {VaultUtils} from "../../../VaultUtils";
import {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";
import chai from "chai";
import chaiAsPromised from "chai-as-promised";
import {DeployInfo} from "../../DeployInfo";
import {TestAsserts} from "../../../TestAsserts";
import {MBUtils} from "./MBUtils";

const {expect} = chai;
chai.use(chaiAsPromised);

export class MBTargetPercentageTest extends SpecificStrategyTest {

  public async do(
    deployInfo: DeployInfo
  ): Promise<void> {
    it("Target percentage", async () => {
      console.log('>>>Target percentage test');
      const underlying = deployInfo?.underlying as string;
      const user = deployInfo?.user as SignerWithAddress;
      const vault = deployInfo?.vault as SmartVault;
      const strategy = deployInfo?.strategy as IStrategy;
      console.log('>>>Target percentage 1');
      await MBUtils.refuelMAI(user, strategy.address);
      console.log('>>>Target percentage 2');

      const bal = await TokenUtils.balanceOf(underlying, user.address);
      console.log('>>>Target percentage 3');

      const strategyMaiBal = deployInfo.strategy as StrategyMaiBal;
      console.log('>>>Target percentage 4');
      const strategyGov = strategyMaiBal.connect(deployInfo.signer as SignerWithAddress);

      console.log('>>>Target percentage 5');
      const targetPercentageInitial = await strategyGov.targetPercentage()
      console.log('>>>targetPercentageInitial', targetPercentageInitial.toString());

      await VaultUtils.deposit(user, vault, BigNumber.from(bal));
      console.log('>>>deposited');
      const bal1 = await strategyGov.getMostUnderlyingBalance()
      console.log('>>>bal1', bal1.toString());

      // increase collateral to debt percentage twice, so debt should be decreased twice
      const targetPercentage1 = targetPercentageInitial.mul(2)
      await expect(strategyGov.setTargetPercentage(targetPercentage1))
        .to.emit(strategyGov, 'SetTargetPercentage')
        .withArgs(targetPercentage1)

      const targetPercentage2 = await strategyGov.targetPercentage()
      console.log('>>>targetPercentage2', targetPercentage2.toString())

      const bal2 = await strategyGov.getMostUnderlyingBalance()
      console.log('>>>bal2', bal2.toString());

      // return target percentage back, so debt should be increased twice
      await expect(strategyGov.setTargetPercentage(targetPercentageInitial))
        .to.emit(strategyGov, 'SetTargetPercentage')
        .withArgs(targetPercentageInitial)
      const targetPercentage3 = await strategyGov.targetPercentage()
      console.log('>>>targetPercentage3', targetPercentage3.toString())

      const bal3 = await strategyGov.getMostUnderlyingBalance()
      console.log('>>>bal3', bal3.toString());
      const dec = await TokenUtils.decimals(underlying);
      TestAsserts.closeTo(bal2, bal1.div(2), 0.005, dec);
      TestAsserts.closeTo(bal3, bal1, 0.005, dec);

    });
  }

}
