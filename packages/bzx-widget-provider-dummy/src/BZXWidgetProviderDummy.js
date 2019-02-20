import EventEmitter from "events";

import { EVENT_ASSET_UPDATE } from "../../bzx-widget-common/src";
import { EVENT_ACCOUNT_UPDATE } from "@bzxnetwork/bzx-widget-common";

export default class BZXWidgetProviderDummy {
  transactionId = "0x";

  account = "0x0000000000000000000000000000000000000000";

  // from packages/bzx.js/src/contracts/rinkeby/WETH.json
  wethAddress = "0xc778417e063141139fce010982780140aa0cd5ab";

  // assets available for selection in the input on top
  assets = [{ num: null, id: "weth", text: "ETH" }];
  // asset to select by default in the input on top
  defaultAsset = "weth";
  // event we emitting when we expect widget to update list of assets
  eventEmitter = new EventEmitter();

  constructor() {
    this.eventEmitter.emit(EVENT_ACCOUNT_UPDATE, this.account);
  }

  getAccount = () => {
    return this.account;
  };

  getLendFormDefaults = () => {
    return {
      qty: "1",
      interestRate: 30,
      duration: 10,
      ratio: 2,
      relays: [],
      pushOnChain: false
    };
  };

  getLendFormOptions = () => {
    return {
      relays: ["Shark", "Veil"],
      ratios: [1, 2, 3],
      interestRateMin: 1,
      interestRateMax: 100,
      durationMin: 1,
      durationMax: 100
    };
  };

  getBorrowFormDefaults = () => {
    return {
      qty: "1",
      interestRate: 30,
      duration: 10,
      ratio: 2,
      relays: [],
      pushOnChain: false
    };
  };

  getBorrowFormOptions = () => {
    return {
      relays: ["Shark", "Veil"],
      ratios: [1, 2, 3],
      interestRateMin: 1,
      interestRateMax: 100,
      durationMin: 1,
      durationMax: 100
    };
  };

  getQuickPositionFormDefaults = () => {
    return {
      qty: "1",
      positionType: "long",
      ratio: 2,
      pushOnChain: false
    };
  };

  getQuickPositionFormOptions = () => {
    return {
      ratios: [1, 2, 3]
    };
  };

  doLendOrderApprove = (value) => {
    console.log("DummyProvider `doLendOrderApprove`:");
    console.dir(value);

    return new Promise((resolve, reject) => {
      resolve(this.transactionId);
    });
  };

  doBorrowOrderApprove = (value) => {
    console.log("DummyProvider `doBorrowOrderApprove`:");
    console.dir(value);

    return new Promise((resolve, reject) => {
      resolve(this.transactionId);
    });
  };

  doQuickPositionApprove = (value) => {
    console.log("DummyProvider `doQuickPositionApprove`:");
    console.dir(value);

    return new Promise((resolve, reject) => {
      resolve(this.transactionId);
    });
  };

  listLoanOrdersBidsAvailable = async (filter, sortComparator, maxCount) => {
    return [];
  };

  listLoanOrdersAsksAvailable = async (filter, sortComparator, maxCount) => {
    return [];
  };

  doLoanOrderTake = async ({ loanOrderHash, loanTokenAddress, collateralTokenAddress, amount, isAsk }) => {
    resolve(this.transactionId);
  };

  doLoanOrderCancel = async ({ loanOrderHash, amount }) => {
    resolve(this.transactionId);
  };

  doLoanOrderWithdrawProfit = async ({ loanOrderHash }) => {
    resolve(this.transactionId);
  };

  doLoanClose = async ({ loanOrderHash }) => {
    resolve(this.transactionId);
  };

  doLoanTradeWithCurrentAsset = async value => {
    resolve(this.transactionId);
  };

  listLoansActive = async maxCount => {
    return [];
  };

  getTokenNameFromAddress = tokenAddress => {
    return tokenAddress.toLowerCase() === this.wethAddress.toLowerCase() ? "WETH" : "Token";
  };

  getMarginLevels = async loanOrderHash => {
    return {
      initialMarginAmount: 50,
      maintenanceMarginAmount: 25,
      currentMarginAmount: 50
    };
  };

  getPositionOffset = async loanOrderHash => {
    return {
      isPositive: true,
      offsetAmount: 0,
      positionTokenAddress: this.wethAddress
    };
  };

  isWethToken = tokenAddress => {
    return tokenAddress.toLowerCase() === this.wethAddress.toLowerCase();
  };

  getSingleOrder = async loanOrderHash => {
    reject("error happened while processing your request");
  };

  _handleAssetsUpdate() {
    this.eventEmitter.emit(EVENT_ASSET_UPDATE, this.assets, this.defaultAsset);
  }
}
