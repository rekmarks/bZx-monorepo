import Augur from "augur.js";
import BigNumber from "bignumber.js";
import { BZxJS } from "@bzxnetwork/bzx.js";
import EventEmitter from "events";
import moment from "moment";
import Web3 from "web3";

import { parseUrlGetParams, zeroAddress } from "./utils";
import { EVENT_ACCOUNT_UPDATE, EVENT_ASSET_UPDATE, EVENT_INIT_FAILED } from "@bzxnetwork/bzx-widget-common";

BigNumber.config({ EXPONENTIAL_AT: 20, ERRORS: false });

export default class BZXWidgetProviderAugur {
  networkId = 4;
  defaultGasAmount = 4000000;
  defaultGasPrice = new BigNumber(12).times(1e9).toFixed();
  batchSize = 50;

  // from packages/bzx.js/src/contracts/rinkeby/WETH.json
  wethAddress = "0xc778417e063141139fce010982780140aa0cd5ab";
  // from packages/bzx.js/src/contracts/rinkeby/BZx.json
  bzxAddress = "0x4db8a61f9cd0cf4998aa4612dd612ab4f4f5a730";
  // from packages/bzx.js/src/contracts/rinkeby/BZxVault.json
  bzxVaultAddress = "0x8f254255592e6e210cc9a464cfa2464da2467df6";
  bZxOracleAddress = "";
  bzxAugurOracleAddress = "";

  // assets available for selection in the input on top
  assets = [];
  // asset to select by default in the input on top
  defaultAsset = "";

  account = "";
  eventEmitter = new EventEmitter();

  constructor() {
    this._subscribeToUrlChanges();

    // reading web3 instance from window
    let { web3 } = window;
    const alreadyInjected = typeof web3 !== `undefined`;
    if (alreadyInjected) {
      this.web3 = new Web3(web3.currentProvider);
      this.web3.currentProvider.publicConfigStore.on("update", result =>
        this.eventEmitter.emit(EVENT_ACCOUNT_UPDATE, result ? result.selectedAddress : "")
      );
      this.web3.currentProvider.enable().then(
        result => {
          this.account = result[0];
          this.eventEmitter.emit(EVENT_ACCOUNT_UPDATE, this.account);

          // init bzxjs
          this.bzxjs = new BZxJS(this.web3, { networkId: this.networkId });
          this.bzxjs.getOracleList().then(
            oracles => {
              console.dir(oracles);

              const bZxOracle = oracles.filter(oracle => oracle.name === "bZxOracle")[0];
              const augurOracle = oracles.filter(oracle => oracle.name === "AugurOracle")[0];
              if (augurOracle && bZxOracle) {
                this.bZxOracleAddress = bZxOracle.address;
                this.bzxAugurOracleAddress = augurOracle.address;

                // creating augur instance
                this.augur = new Augur();
                // connecting to augur instance
                this.augur.connect(
                  // at the current time _getAugurConnectivity returns only rinkeby data
                  this._getAugurConnectivity(),
                  (err, connectionInfo) => {
                    this._refreshAssets();
                  }
                );
              } else {
                if (!bZxOracle) {
                  this.eventEmitter.emit(EVENT_INIT_FAILED, "no `bZxOracle` oracle available");
                }

                if (!augurOracle) {
                  this.eventEmitter.emit(EVENT_INIT_FAILED, "no `AugurOracle` oracle available");
                }
              }
            },
            () => this.eventEmitter.emit(EVENT_INIT_FAILED, "unable to get list of oracles available")
          );
        },
        () => this.eventEmitter.emit(EVENT_INIT_FAILED, "unable to enable web3 provider")
      );
    } else {
      // widget is not listening eventEmitter at this place, so let's write to console at least
      console.log("web3 provider is not available");
    }
  }

  getLendFormDefaults = () => {
    return {
      qty: "1",
      interestRate: 30,
      duration: 10,
      ratio: 2,
      relays: [],
      pushOnChain: true
    };
  };

  getLendFormOptions = () => {
    return {
      relays: ["Shark", "Veil"],
      ratios: [1, 2, 4],
      interestRateMin: 1,
      interestRateMax: 100,
      durationMin: 1,
      durationMax: 28
    };
  };

  getBorrowFormDefaults = () => {
    return {
      qty: "1",
      interestRate: 30,
      duration: 10,
      ratio: 2,
      relays: [],
      pushOnChain: true
    };
  };

  getBorrowFormOptions = () => {
    return {
      relays: ["Shark", "Veil"],
      ratios: [1, 2, 4],
      interestRateMin: 1,
      interestRateMax: 100,
      durationMin: 1,
      durationMax: 28
    };
  };

  getQuickPositionFormDefaults = () => {
    return {
      qty: "1",
      positionType: "long",
      ratio: 2,
      pushOnChain: true
    };
  };

  getQuickPositionFormOptions = () => {
    return {
      ratios: [1, 2, 4]
    };
  };

  listLoansActive = async maxCount => {
    let loansForLender = await this.bzxjs.getLoansForLender({
      address: this.account.toLowerCase(),
      count: maxCount,
      activeOnly: true
    });
    let loansForTrader = await this.bzxjs.getLoansForTrader({
      address: this.account.toLowerCase(),
      count: maxCount,
      activeOnly: true
    });

    // TODO: filtering with target market
    const assetsAddresses = this.assets.map(e => e.id.toLowerCase());
    return loansForLender
      .concat(loansForTrader)
      .filter(e => assetsAddresses.includes(e.loanTokenAddress.toLowerCase()))
      .sort((e1, e2) => e2.loanStartUnixTimestampSec - e1.loanStartUnixTimestampSec)
      .slice(0, maxCount);
  };

  listLoanOrdersBidsAvailable = async (filter, sortComparator, maxCount) => {
    // orders where maker role is lender (lending bids (proposal))

    let currentPage = 0;
    let results = [];
    let pageResults = [];
    const assetsAddresses = this.assets.map(e => e.id.toLowerCase());
    do {
      pageResults = await this.bzxjs.getOrdersFillable({
        start: maxCount * currentPage,
        count: maxCount * (currentPage + 1),
        oracleFilter: this.bzxAugurOracleAddress.toLowerCase()
      });
      pageResults = pageResults.filter(filter);
      // TODO: filtering with target market
      pageResults = pageResults.filter(
        e =>
          e.collateralTokenAddress.toLowerCase() === zeroAddress.toLowerCase() &&
          assetsAddresses.includes(e.loanTokenAddress.toLowerCase())
      );

      results = results.concat(pageResults);
      currentPage++;
    } while (pageResults.length < 0);

    return results.slice(0, maxCount);
  };

  listLoanOrdersAsksAvailable = async (filter, sortComparator, maxCount) => {
    // orders where maker role is borrower (lending asks (request))

    let currentPage = 0;
    let results = [];
    let pageResults = [];
    const assetsAddresses = this.assets.map(e => e.id.toLowerCase());
    do {
      pageResults = await this.bzxjs.getOrdersFillable({
        start: maxCount * currentPage,
        count: maxCount * (currentPage + 1),
        oracleFilter: this.bzxAugurOracleAddress.toLowerCase()
      });
      pageResults = pageResults.filter(filter);
      // TODO: filtering with target market
      pageResults = pageResults.filter(
        e =>
          e.collateralTokenAddress.toLowerCase() !== zeroAddress.toLowerCase() &&
          assetsAddresses.includes(e.loanTokenAddress.toLowerCase())
      );

      results = results.concat(pageResults);
      currentPage++;
    } while (pageResults.length < 0);

    return results.sort(sortComparator).slice(0, maxCount);
  };

  getMarginLevels = async loanOrderHash => {
    return await this.bzxjs.getMarginLevels({ loanOrderHash, trader: this.account.toString() });
  };

  getPositionOffset = async loanOrderHash => {
    return await this.bzxjs.getPositionOffset({ loanOrderHash, trader: this.account.toString() });
  };

  getTokenNameFromAddress = tokenAddress => {
    return tokenAddress.toLowerCase() === this.wethAddress.toLowerCase() ? "WETH" : "Augur token";
  };

  getAccount = () => {
    return this.account.toString();
  };

  getSingleOrder = async loanOrderHash => {
    return new Promise((resolve, reject) => {
      try {
        this._getSingleOrder(loanOrderHash, resolve, reject);
      } catch (e) {
        console.dir(e);
        reject("error happened while processing your request");
      }
    });
  };

  isWethToken = tokenAddress => {
    return tokenAddress.toLowerCase() === this.wethAddress.toLowerCase();
  };

  doLoanOrderWithdrawProfit = async ({ loanOrderHash, withdrawAmount }) => {
    return new Promise((resolve, reject) => {
      try {
        this._handleLoanOrderWithdrawProfit(loanOrderHash, withdrawAmount, resolve, reject);
      } catch (e) {
        console.dir(e);
        reject("error happened while processing your request");
      }
    });
  };

  doLoanOrderCancel = async ({ loanOrderHash, amount }) => {
    return new Promise((resolve, reject) => {
      try {
        this._handleLoanOrderCancel(loanOrderHash, amount, resolve, reject);
      } catch (e) {
        console.dir(e);
        reject("error happened while processing your request");
      }
    });
  };

  doLoanClose = async ({ loanOrderHash }) => {
    return new Promise((resolve, reject) => {
      try {
        this._handleLoanClose(loanOrderHash, resolve, reject);
      } catch (e) {
        console.dir(e);
        reject("error happened while processing your request");
      }
    });
  };

  doLoanOrderTake = async ({ loanOrderHash, loanTokenAddress, collateralTokenAddress, amount, isAsk }) => {
    return new Promise((resolve, reject) => {
      try {
        this._handleLoanOrderTake(
          loanOrderHash,
          loanTokenAddress,
          collateralTokenAddress,
          amount,
          isAsk,
          resolve,
          reject
        );
      } catch (e) {
        console.dir(e);
        reject("error happened while processing your request");
      }
    });
  };

  doLendOrderApprove = async value => {
    return new Promise((resolve, reject) => {
      try {
        this._handleLendOrderApprove(value, resolve, reject);
      } catch (e) {
        console.dir(e);
        reject("error happened while processing your request");
      }
    });
  };

  doBorrowOrderApprove = async value => {
    return new Promise((resolve, reject) => {
      try {
        this._handleBorrowOrderApprove(value, resolve, reject);
      } catch (e) {
        console.dir(e);
        reject("error happened while processing your request");
      }
    });
  };

  doQuickPositionApprove = async value => {
    return new Promise((resolve, reject) => {
      try {
        this._handleQuickPositionApprove(value, resolve, reject);
      } catch (e) {
        console.dir(e);
        reject("error happened while processing your request");
      }
    });
  };

  doLoanTradeWithCurrentAsset = async value => {
    return new Promise((resolve, reject) => {
      try {
        this._handleLoanTradeWithCurrentAsset(value, resolve, reject);
      } catch (e) {
        console.dir(e);
        reject("error happened while processing your request");
      }
    });
  };

  _getAugurConnectivity = () => {
    //TODO: use this.networkId

    const ethereumNode = {
      httpAddresses: [
        "https://rinkeby.augur.net/ethereum-http", // hosted http address for Geth node on the Rinkeby test network
        "https://rinkeby.infura.io/"
      ],
      wsAddresses: [
        "wss://rinkeby.augur.net/ethereum-ws", // hosted WebSocket address for Geth node on the Rinkeby test network
        "wss://rinkeby.infura.io/ws/"
      ]
    };

    const augurNode = "wss://dev.augur.net/augur-node";

    return { ethereumNode, augurNode };
  };

  _getAugurMarkedId = () => {
    let params = parseUrlGetParams();
    return params.id;
  };

  _getAugurMarketShareOutcomeNumber = async (currentMarketId, shareTokenAddress) => {
    const filteredOutcomes = this.assets
      .filter(e => e.id.toLowerCase() === shareTokenAddress.toLowerCase())
      .map(e => e.num);

    return filteredOutcomes.length > 0 ? filteredOutcomes[0] : null;
  };

  _subscribeToUrlChanges = () => {
    let that = this;

    window.addEventListener("hashchange", that._refreshAssets, false);
    window.addEventListener("onpopstate", that._refreshAssets, false);
  };

  _getAAugurMarketOutcomes = async augurMarketId => {
    const getMarketsPromise = new Promise((resolve, reject) => {
      this.augur.markets.getMarketsInfo({ marketIds: [augurMarketId] }, (error, result) => {
        if (error) {
          reject(error);
        } else {
          resolve(result);
        }
      });
    });
    const result = await getMarketsPromise;

    // getting shares tokens list
    const outcomesMap = result[0].outcomes
      .filter(e => !(e.id === 0 && result[0].marketType === "scalar"))
      .map(async e => {
      const shareTokenAddress = await this.augur.api.Market.getShareToken({
        _outcome: this.augur.utils.convertBigNumberToHexString(new BigNumber(e.id)),
        tx: { to: augurMarketId }
      });

      let outcomeName = "";
      let outcomePrice = new BigNumber(e.price).toFormat(2);
      let outcomeMinPrice = new BigNumber(result[0].minPrice).toFormat(2);
      let outcomeMaxPrice = new BigNumber(result[0].maxPrice).toFormat(2);
      if (result[0].marketType === "scalar") {
        outcomeName = `${outcomeMinPrice} / ${outcomePrice} / ${outcomeMaxPrice}`;
      } else if (result[0].marketType === "categorical") {
        outcomeName = `${e.description}: ${outcomePrice}`;
      } else if (result[0].marketType === "yesNo") {
        outcomeName = `${e.id === 0 ? "NO: " : "YES: "}${outcomePrice}`;
      } else {
        outcomeName = "unknown market type";
      }

      const shareTokenText = `${outcomeName} // volume: ${e.volume} // address: ${shareTokenAddress}`;

      return { num: e.id, id: shareTokenAddress, text: shareTokenText };
    });

    return await Promise.all(outcomesMap);
  };

  _refreshAssets = async () => {
    // getting marketId from url "id" param
    const currentMarketId = this._getAugurMarkedId();
    if (currentMarketId) {
      const wethTokenContractAddress = this.wethAddress.toLowerCase();

      const outcomes = await this._getAAugurMarketOutcomes(currentMarketId);
      outcomes.unshift({ num: null, id: wethTokenContractAddress, text: "WETH" });

      this.assets = outcomes;
      this.defaultAsset = wethTokenContractAddress;

      this._handleAssetsUpdate();
    } else {
      // if we are not on the market page we must clean available assets
      this.assets = [];
      this.defaultAsset = "";

      // let's ask widget to update assets list
      this._handleAssetsUpdate();
    }
  };

  _handleAssetsUpdate = () => {
    this.eventEmitter.emit(EVENT_ASSET_UPDATE, this.assets, this.defaultAsset);
  };

  _getSingleOrder = async (loanOrderHash, resolve, reject) => {
    try {
      const result = await this.bzxjs.getSingleOrder({ loanOrderHash: loanOrderHash.toLowerCase() });
      resolve(result);
    } catch (e) {
      console.dir(e);
      reject("error happened while processing your request");
      return;
    }
  };

  _handleLoanOrderWithdrawProfit = async (loanOrderHash, withdrawAmount, resolve, reject) => {
    try {
      let transactionReceipt = await this.bzxjs.withdrawPosition({
        loanOrderHash: loanOrderHash.toLowerCase(),
        withdrawAmount: withdrawAmount.toFixed(),
        getObject: false,
        txOpts: { from: this.account.toLowerCase(), gasPrice: this.defaultGasPrice, gas: this.defaultGasAmount }
      });
      console.dir(transactionReceipt);

      resolve(transactionReceipt.transactionHash);
    } catch (e) {
      console.dir(e);
      reject("error happened while processing your request");
      return;
    }
  };

  _handleLoanOrderCancel = async (loanOrderHash, amount, resolve, reject) => {
    try {
      let transactionReceipt = await this.bzxjs.cancelLoanOrderWithHash({
        loanOrderHash: loanOrderHash.toLowerCase(),
        cancelLoanTokenAmount: amount.toString(),
        getObject: false,
        txOpts: { from: this.account.toLowerCase(), gasPrice: this.defaultGasPrice, gas: this.defaultGasAmount }
      });
      console.dir(transactionReceipt);

      resolve(transactionReceipt.transactionHash);
    } catch (e) {
      console.dir(e);
      reject("error happened while processing your request");
      return;
    }
  };

  _handleLoanClose = async (loanOrderHash, resolve, reject) => {
    try {
      let transactionReceipt = await this.bzxjs.closeLoan({
        loanOrderHash: loanOrderHash.toLowerCase(),
        getObject: false,
        txOpts: { from: this.account.toLowerCase(), gasPrice: this.defaultGasPrice, gas: this.defaultGasAmount }
      });

      resolve(transactionReceipt.transactionHash);
    } catch (e) {
      console.dir(e);
      reject("error happened while processing your request");
      return;
    }
  };

  _handleLoanOrderTake = async (
    loanOrderHash,
    loanTokenAddress,
    collateralTokenAddress,
    amount,
    isAsk,
    resolve,
    reject
  ) => {
    try {
      let transactionReceipt = await this.bzxjs.setAllowanceUnlimited({
        tokenAddress: this.wethAddress.toLowerCase(),
        ownerAddress: this.account,
        spenderAddress: this.bzxVaultAddress.toLowerCase(),
        getObject: false,
        txOpts: { from: this.account.toLowerCase(), gasPrice: this.defaultGasPrice }
      });
      console.dir(transactionReceipt);

      if (isAsk) {
        transactionReceipt = await this.bzxjs.setAllowanceUnlimited({
          tokenAddress: loanTokenAddress.toLowerCase(),
          ownerAddress: this.account.toLowerCase(),
          spenderAddress: this.bzxVaultAddress.toLowerCase(),
          getObject: false,
          txOpts: { from: this.account.toLowerCase(), gasPrice: this.defaultGasPrice, gas: this.defaultGasAmount }
        });
        console.dir(transactionReceipt);

        transactionReceipt = await this.bzxjs.takeLoanOrderOnChainAsLender({
          loanOrderHash: loanOrderHash.toLowerCase(),
          getObject: false,
          txOpts: { from: this.account.toLowerCase(), gasPrice: this.defaultGasPrice, gas: this.defaultGasAmount }
        });
      } else {
        transactionReceipt = await this.bzxjs.setAllowanceUnlimited({
          tokenAddress: collateralTokenAddress.toLowerCase(),
          ownerAddress: this.account.toLowerCase(),
          spenderAddress: this.bzxVaultAddress.toLowerCase(),
          getObject: false,
          txOpts: { from: this.account.toLowerCase(), gasPrice: this.defaultGasPrice, gas: this.defaultGasAmount }
        });
        console.dir(transactionReceipt);

        transactionReceipt = await this.bzxjs.takeLoanOrderOnChainAsTrader({
          loanOrderHash: loanOrderHash.toLowerCase(),
          collateralTokenAddress: this.wethAddress.toLowerCase(),
          loanTokenAmountFilled: amount.toString(),
          tradeTokenToFillAddress: zeroAddress.toLowerCase(),
          withdrawOnOpen: false,
          getObject: false,
          txOpts: { from: this.account.toLowerCase(), gasPrice: this.defaultGasPrice, gas: this.defaultGasAmount }
        });
      }
      console.dir(transactionReceipt);

      resolve(transactionReceipt.transactionHash);
    } catch (e) {
      console.dir(e);
      reject("error happened while processing your request");
      return;
    }
  };

  _preValidateLendOrderApprove = value => {
    if (!value.asset) {
      return { isValid: false, message: "asset is not selected" };
    }

    if (!value.pushOnChain) {
      return { isValid: false, message: "pushing to relay is not yet supported" };
    }

    return { isValid: true, message: "" };
  };

  _handleLendOrderApprove = async (value, resolve, reject) => {
    // The user creates bzx order to lend current market tokens he already owns.

    try {
      let validationResult = this._preValidateLendOrderApprove(value);
      if (!validationResult.isValid) {
        reject(validationResult.message);
        return;
      }

      const lenderAddress = this.account.toLowerCase();
      console.log(`lenderAddress: ${lenderAddress}`);

      let transactionReceipt;

      const orderOracleAddress = this.bzxAugurOracleAddress.toLowerCase();
      // const orderOracleAddress = this.bZxOracleAddress.toLowerCase();
      const orderOracleData = this._getAugurMarkedId();
      // const orderOracleData = "0x";

      // SHOULD BE WITH DENOMINATION
      const loanAmountInBaseUnits = new BigNumber(this.web3.utils.toWei(value.qty, "ether"));
      const convertedToWeiAmount =
        value.asset === this.wethAddress
          ? loanAmountInBaseUnits
          : this._convertWithConversionData(
            loanAmountInBaseUnits,
            await this.bzxjs.getConversionData(
              value.asset.toLowerCase(),
              this.wethAddress.toLowerCase(),
              loanAmountInBaseUnits.toFixed(),
              orderOracleAddress
            )
          );
      if (convertedToWeiAmount.eq(0) || convertedToWeiAmount.isNaN()) {
        reject("not enough liquidity");
        return;
      }

      // CALCULATING MARGIN AMOUNT FROM "RATIO" (100 / RATIO) * 10^18
      // .integerValue(BigNumber.ROUND_CEIL); required for future conversion with bn.js (fractional part is not supported)
      const initialMarginAmount = (new BigNumber(100)).multipliedBy(1e18).dividedBy(new BigNumber(value.ratio)).integerValue(BigNumber.ROUND_CEIL);
      console.log(`initialMarginAmount: ${initialMarginAmount.toFixed(0)}`);
      const maintenanceMarginAmount = initialMarginAmount.dividedBy(2).integerValue(BigNumber.ROUND_CEIL);
      console.log(`maintenanceMarginAmount: ${maintenanceMarginAmount.toFixed(0)}`);

      // CALCULATING INTEREST AS % FROM LOAN
      const interestAmount = convertedToWeiAmount
        .multipliedBy(new BigNumber(value.interestRate))
        .dividedBy(value.duration)
        .dividedBy(100)
        .integerValue(BigNumber.ROUND_CEIL);
      console.log(`interestAmount: ${interestAmount.toFixed()}`);

      console.log("setting allowance for share's token");
      transactionReceipt = await this.bzxjs.setAllowanceUnlimited({
        tokenAddress: value.asset.toLowerCase(),
        ownerAddress: lenderAddress,
        spenderAddress: this.bzxVaultAddress.toLowerCase(),
        getObject: false,
        txOpts: { from: lenderAddress, gasPrice: this.defaultGasPrice }
      });
      console.dir(transactionReceipt);

      console.log("creating lend order");
      const lendOrder = {
        bZxAddress: this.bzxAddress.toLowerCase(),
        makerAddress: lenderAddress.toLowerCase(),
        takerAddress: zeroAddress.toLowerCase(),
        tradeTokenToFillAddress: zeroAddress.toLowerCase(),
        withdrawOnOpen: "0",
        loanTokenAddress: value.asset.toLowerCase(),
        interestTokenAddress: this.wethAddress.toLowerCase(),
        collateralTokenAddress: zeroAddress.toLowerCase(),
        feeRecipientAddress: zeroAddress.toLowerCase(),
        oracleAddress: orderOracleAddress.toLowerCase(),
        loanTokenAmount: loanAmountInBaseUnits.toFixed(),
        interestAmount: interestAmount.toFixed(),
        initialMarginAmount: initialMarginAmount.toFixed(0),
        maintenanceMarginAmount: maintenanceMarginAmount.toFixed(0),
        // USING CONSTANTS BELOW
        lenderRelayFee: "0",
        traderRelayFee: "0",
        // EXPECTING DURATION IN DAYS
        maxDurationUnixTimestampSec: (value.duration * 86400).toString(),
        expirationUnixTimestampSec: moment()
          .add(7, "day")
          .unix()
          .toString(), // 7 days
        makerRole: "0", // 0=LENDER, 1=TRADER
        salt: BZxJS.generatePseudoRandomSalt().toString()
      };
      console.dir(lendOrder);

      console.log("signing lend order");
      const lendOrderHash = BZxJS.getLoanOrderHashHex({
        ...lendOrder,
        oracleData: orderOracleData.toLowerCase()
      });
      console.log(`lendOrderHash: ${lendOrderHash}`);

      const lendOrderSignature = await this.bzxjs.signOrderHashAsync(lendOrderHash, lenderAddress, true);
      console.log(`lendOrderSignature: ${lendOrderSignature}`);

      const signedLendOrder = { ...lendOrder, signature: lendOrderSignature };

      if (value.pushOnChain) {
        console.log("pushing order on-chain");
        transactionReceipt = await this.bzxjs.pushLoanOrderOnChain({
          order: signedLendOrder,
          oracleData: orderOracleData.toLowerCase(),
          getObject: false,
          txOpts: { from: lenderAddress, gasPrice: this.defaultGasPrice, gas: this.defaultGasAmount }
        });
        console.dir(transactionReceipt);

        resolve(transactionReceipt.transactionHash);
        return;
      } else {
        reject("pushing to relay is not yet supported");
        return;
      }
    } catch (e) {
      console.dir(e);
      reject("error happened while processing your request");
      return;
    }
  };

  _preValidateBorrowOrderApprove = value => {
    if (!value.asset) {
      return { isValid: false, message: "asset is not selected" };
    }

    if (!value.pushOnChain) {
      return { isValid: false, message: "pushing to relay is not yet supported" };
    }

    return { isValid: true, message: "" };
  };

  _handleBorrowOrderApprove = async (value, resolve, reject) => {
    // The user creates bzx order to borrow eth for future trade on the current market.

    try {
      let validationResult = this._preValidateBorrowOrderApprove(value);
      if (!validationResult.isValid) {
        reject(validationResult.message);
        return;
      }

      const borrowerAddress = this.account.toLowerCase();
      console.log(`borrowerAddress: ${borrowerAddress}`);

      let transactionReceipt;

      const orderOracleAddress = this.bzxAugurOracleAddress.toLowerCase();
      // const orderOracleAddress = this.bZxOracleAddress.toLowerCase();
      const orderOracleData = this._getAugurMarkedId();
      // const orderOracleData = "0x";

      // SHOULD BE WITH DENOMINATION
      const borrowAmountInBaseUnits = new BigNumber(this.web3.utils.toWei(value.qty, "ether"));
      const convertedToWeiAmount =
        value.asset === this.wethAddress
          ? borrowAmountInBaseUnits
          : this._convertWithConversionData(
            borrowAmountInBaseUnits,
            await this.bzxjs.getConversionData(
              value.asset.toLowerCase(),
              this.wethAddress.toLowerCase(),
              borrowAmountInBaseUnits.toFixed(),
              orderOracleAddress
            )
      );
      if (convertedToWeiAmount.eq(0) || convertedToWeiAmount.isNaN()) {
        reject("not enough liquidity");
        return;
      }

      // CALCULATING MARGIN AMOUNT FROM "RATIO" (100 / RATIO)
      // .integerValue(BigNumber.ROUND_CEIL); required for future conversion with bn.js (fractional part is not supported)
      const initialMarginAmount = (new BigNumber(100)).multipliedBy(1e18).dividedBy(new BigNumber(value.ratio)).integerValue(BigNumber.ROUND_CEIL);
      console.log(`initialMarginAmount: ${initialMarginAmount.toFixed(0)}`);
      const maintenanceMarginAmount = initialMarginAmount.dividedBy(2).integerValue(BigNumber.ROUND_CEIL);
      console.log(`maintenanceMarginAmount: ${maintenanceMarginAmount.toFixed(0)}`);

      // CALCULATING INTEREST AS % FROM LOAN
      const interestAmount = convertedToWeiAmount
        .multipliedBy(new BigNumber(value.interestRate))
        .dividedBy(value.duration)
        .dividedBy(100)
        .integerValue(BigNumber.ROUND_CEIL);
      console.log(`interestAmount: ${interestAmount.toFixed()}`);

      console.log("setting allowance for collateral token (weth)");
      transactionReceipt = await this.bzxjs.setAllowanceUnlimited({
        tokenAddress: this.wethAddress.toLowerCase(),
        ownerAddress: borrowerAddress,
        spenderAddress: this.bzxVaultAddress.toLowerCase(),
        getObject: false,
        txOpts: { from: borrowerAddress, gasPrice: this.defaultGasPrice }
      });
      console.dir(transactionReceipt);

      console.log("creating borrow order");
      const borrowOrder = {
        bZxAddress: this.bzxAddress.toLowerCase(),
        makerAddress: borrowerAddress.toLowerCase(),
        takerAddress: zeroAddress.toLowerCase(),
        tradeTokenToFillAddress: zeroAddress.toLowerCase(),
        withdrawOnOpen: "0",
        loanTokenAddress: value.asset.toLowerCase(),
        interestTokenAddress: this.wethAddress.toLowerCase(),
        collateralTokenAddress: this.wethAddress.toLowerCase(),
        feeRecipientAddress: zeroAddress.toLowerCase(),
        oracleAddress: orderOracleAddress.toLowerCase(),
        loanTokenAmount: borrowAmountInBaseUnits.toFixed(),
        interestAmount: interestAmount.toFixed(),
        initialMarginAmount: initialMarginAmount.toFixed(0),
        maintenanceMarginAmount: maintenanceMarginAmount.toFixed(0),
        // USING CONSTANTS BELOW
        lenderRelayFee: "0",
        traderRelayFee: "0",
        // EXPECTING DURATION IN DAYS
        maxDurationUnixTimestampSec: (value.duration * 86400).toString(),
        expirationUnixTimestampSec: moment()
          .add(7, "day")
          .unix()
          .toString(), // 7 days
        makerRole: "1", // 0=LENDER, 1=TRADER
        salt: BZxJS.generatePseudoRandomSalt().toString()
      };
      console.dir(borrowOrder);

      console.log("signing borrow order");
      const borrowOrderHash = BZxJS.getLoanOrderHashHex({
        ...borrowOrder,
        oracleData: orderOracleData.toLowerCase()
      });
      console.log(`borrowOrderHash: ${borrowOrderHash}`);

      const borrowOrderSignature = await this.bzxjs.signOrderHashAsync(borrowOrderHash, borrowerAddress, true);
      console.log(`borrowOrderSignature: ${borrowOrderSignature}`);

      const signedBorrowOrder = { ...borrowOrder, signature: borrowOrderSignature };

      if (value.pushOnChain) {
        console.log("pushing order on-chain");
        transactionReceipt = await this.bzxjs.pushLoanOrderOnChain({
          order: signedBorrowOrder,
          oracleData: orderOracleData.toLowerCase(),
          getObject: false,
          txOpts: { from: borrowerAddress, gasPrice: this.defaultGasPrice, gas: this.defaultGasAmount }
        });
        console.dir(transactionReceipt);

        resolve(transactionReceipt.transactionHash);
        return;
      } else {
        reject("pushing to relay is not yet supported");
        return;
      }
    } catch (e) {
      console.dir(e);
      reject("error happened while processing your request");
      return;
    }
  };

  _convertWithConversionData = (value, conv) => {
    // let result = value.multipliedBy(new BigNumber(conv.rate));
    //
    // const precision = new BigNumber(conv.precision);
    // if (!precision.isZero()) {
    //   result = result.dividedBy(precision);
    // }
    //
    // return result;
    let rate = (new BigNumber(conv.rate)).dividedBy(1e18);
    let result = value.dividedBy(rate);

    console.log(`rate: ${rate.toFixed()}`);
    console.log(`result: ${result.toFixed()}`);

    return result;
  };

  _preValidateQuickPositionApprove = value => {
    if (!value.asset) {
      return { isValid: false, message: "asset is not selected" };
    }

    if (value.asset.toLowerCase() === this.wethAddress) {
      return { isValid: false, message: "unable open quick position with ETH" };
    }

    if (!value.pushOnChain) {
      return { isValid: false, message: "pushing to relay is not yet supported" };
    }

    return { isValid: true, message: "" };
  };

  _handleQuickPositionApprove = async (value, resolve, reject) => {
    try {
      let validationResult = this._preValidateQuickPositionApprove(value);
      if (!validationResult.isValid) {
        reject(validationResult.message);
        return;
      }

      if (value.positionType === "long") {
        await this._handleLeverageLong(value, resolve, reject);
      } else if (value.positionType === "short") {
        await this._handleLeverageShort(value, resolve, reject);
      } else {
        reject("something went wrong");
        return;
      }
    } catch (e) {
      console.dir(e);
      reject("error happened while processing your request");
      return;
    }
  };

  _handleLeverageLong = async (value, resolve, reject) => {
    // Leverage long:
    // - find order lowest ask (seller's price) at augur
    // - calculate required ETH amount (using augur orders)
    // - find in bzx ETH lend orders with approved current market
    // - take ETH lend order
    // - buy tokens at augur market using bzx

    if (value.ratio === 1) {
      reject("unable to open long position with 1x leverage (your margin will be equal to leveraged funds)");
      return;
    }

    const marketId = this._getAugurMarkedId();
    console.log(`marketId: ${marketId}`);

    console.log("looking for augur orders");
    const sellOrders = await this._findAugurLowestAskSellOrders(marketId, value.asset.toLowerCase(), value.qty);
    if (sellOrders.length === 0) {
      reject("not enough liquidity (augur outcome)");
      return;
    }

    const ethAmountToBorrow = await this._getEthAmountToBorrow(sellOrders, value.qty);
    console.log(`ethAmountToBorrow: ${ethAmountToBorrow}`);
    const weiAmountToBorrow = this.web3.utils.toWei(ethAmountToBorrow.toFixed(18), "ether").toString();
    console.log(`weiAmountToBorrow: ${weiAmountToBorrow}`);

    console.log("looking for bzx orders");
    const ethLendOrders = await this._findLendOrdersForCurrentMarket(marketId, this.wethAddress, weiAmountToBorrow);
    if (ethLendOrders.length === 0) {
      reject("not enough liquidity (bzx lend orders)");
      return;
    }

    await this._takeLendOrders(ethLendOrders, weiAmountToBorrow);
    await this._takeAugurOrdersWithBzx(ethLendOrders, value.asset);

    resolve();
  };

  _handleLeverageShort = async (value, resolve, reject) => {
    // Leverage short:
    // - find in bzx 'market token' lend orders with current market share token
    // - take 'market token' lend order
    // - sell tokens at augur market using bzx (buy weth)

    const marketId = this._getAugurMarkedId();

    const sharesAmountToBorrow = this.web3.utils.toWei(value.qty, "ether");
    console.log(`sharesAmountToBorrow: ${sharesAmountToBorrow}`);

    const sharesLendOrders = await this._findLendOrdersForCurrentMarket(
      marketId,
      value.asset.toLowerCase(),
      sharesAmountToBorrow
    );
    if (sharesLendOrders.length === 0) {
      reject("not enough liquidity (bzx lend orders)");
      return;
    }

    await this._takeLendOrders(sharesLendOrders, sharesAmountToBorrow);
    await this._takeAugurOrdersWithBzx(sharesLendOrders, this.wethAddress);

    resolve();
  };

  _handleLoanTradeWithCurrentAsset = async (value, resolve, reject) => {
    try {
      const transactionReceipt = await this.bzxjs.tradePositionWithOracle({
        orderHash: value.loanOrderHash.toLowerCase(),
        tradeTokenAddress: value.asset.toLowerCase(),
        getObject: false,
        txOpts: { from: this.account.toLowerCase(), gasPrice: this.defaultGasPrice, gas: this.defaultGasAmount }
      });

      resolve(transactionReceipt.transactionHash);
    } catch (e) {
      console.dir(e);
      reject("error happened while processing your request");
      return;
    }
  };

  _findAugurLowestAskSellOrders = async (marketId, marketShareTokenAddress, amount) => {
    const outcomeNumber = await this._getAugurMarketShareOutcomeNumber(marketId, marketShareTokenAddress);
    console.log(`outcomeNumber: ${outcomeNumber}`);

    const augurOrdersPromise = new Promise((resolve, reject) => {
      this.augur.trading.getOrders(
        {
          marketId: marketId,
          outcome: outcomeNumber,
          orderType: "sell",
          orderState: "OPEN",
          orphaned: false,
          sortBy: "price",
          isSortDescending: false
        },
        (error, result) => {
          if (error) {
            reject(error);
          } else {
            resolve(result);
          }
        }
      );
    });

    const singleSideOrderBook = await augurOrdersPromise;
    if (!(marketId.toString().toLowerCase() in singleSideOrderBook)) {
      // not enough liquidity
      return [];
    }
    const orders = singleSideOrderBook[marketId.toString().toLowerCase()];
    console.dir(orders);

    let amountToTake = new BigNumber(amount);
    console.log(`amountToTake: ${amountToTake.toFixed()}`);

    const ordersArray = [];
    for (let num in orders) {
      const orderKeyValueObject = orders[num]["sell"];
      for (let id in orderKeyValueObject) {
        let amountShouldBeTaken = BigNumber.minimum(new BigNumber(orderKeyValueObject[id].fullPrecisionAmount), amountToTake);
        if (amountShouldBeTaken.eq(0)) {
          break;
        }

        amountToTake = amountToTake.minus(amountShouldBeTaken);
        ordersArray.push(orderKeyValueObject[id]);
      }
    }
    if (!amountToTake.eq(0)) {
      // not enough liquidity
      return [];
    }

    console.log("ordersArray");
    console.dir(ordersArray);

    return ordersArray;
  };

  _getEthAmountToBorrow = async (sellOrders, amount) => {
    let amountToTake = new BigNumber(amount);
    let amountToBorrow = new BigNumber(0);
    for (let e of sellOrders) {
      let amountShouldBeTaken = BigNumber.minimum(new BigNumber(e.fullPrecisionAmount), amountToTake);
      if (amountShouldBeTaken.eq(0)) {
        break;
      }

      const tokenPrice = new BigNumber(await this.augur.api.Orders.getPrice({_orderId: e.orderId}));
      console.log(`tokenPrice: ${tokenPrice}`);

      amountToTake = amountToTake.minus(amountShouldBeTaken);
      amountToBorrow = amountToBorrow.plus(amountShouldBeTaken.dividedBy(tokenPrice));
    }

    return amountToBorrow;
  };

  _findLendOrdersForCurrentMarket = async (market, tokenAddress, amount) => {
    let fullLendOrdersList = [];
    const pageSize = 100;
    let readCount = 0;

    let pageContent;
    do {
      pageContent = await this.bzxjs.getOrdersFillable({
        start: readCount,
        count: pageSize,
        oracleFilter: this.bzxAugurOracleAddress.toLowerCase()
      });
      fullLendOrdersList.push(
        ...pageContent.filter(
          e =>
            e.oracleAddress.toLowerCase() === this.bzxAugurOracleAddress.toLowerCase() &&
            // enabled market filter
            // check expiration date. order should be valid for next `default duration days` - for. ex. 3
            e.loanTokenAddress.toLowerCase() === tokenAddress.toLowerCase() &&
            e.makerAddress.toLowerCase() !== this.account.toLowerCase()
        )
      );

      readCount += pageContent.length;
    } while (pageContent.length >= pageSize);
    fullLendOrdersList = fullLendOrdersList.sort((a, b) => {
      const criteriaAmount = a.interestAmount / a.loanTokenAmount - b.interestAmount / b.loanTokenAmount;
      if (criteriaAmount !== 0) return criteriaAmount;

      return b.loanTokenAmount - a.loanTokenAmount;
    });
    console.dir(fullLendOrdersList);

    let amountToTake = new BigNumber(amount);
    console.log(`amountToTake: ${amountToTake.toFixed()}`);
    let filteredLendOrdersList = [];
    for (let lendOrder of fullLendOrdersList) {
      let amountShouldBeTaken = BigNumber.minimum(new BigNumber(lendOrder.loanTokenAmount), amountToTake);
      if (amountShouldBeTaken.eq(0)) {
        break;
      }

      amountToTake = amountToTake.minus(amountShouldBeTaken);
      filteredLendOrdersList.push(lendOrder);
    }
    if (!amountToTake.eq(0)) {
      // not enough liquidity
      return [];
    }

    console.dir(filteredLendOrdersList);

    return filteredLendOrdersList;
  };

  _takeLendOrders = async (orders, amount) => {
    let amountToTake = new BigNumber(amount);
    for (let e of orders) {
      let amountShouldBeTaken = BigNumber.minimum(new BigNumber(e.loanTokenAmount), amountToTake);
      if (amountShouldBeTaken.eq(0)) {
        break;
      }

      console.log(`Taking order ${e.loanOrderHash}, ${amountShouldBeTaken}`);
      let transactionReceipt = await this.bzxjs.takeLoanOrderOnChainAsTrader({
        loanOrderHash: e.loanOrderHash.toLowerCase(),
        collateralTokenAddress: this.wethAddress.toLowerCase(),
        loanTokenAmountFilled: amountShouldBeTaken.toFixed(),
        tradeTokenToFillAddress: zeroAddress.toLowerCase(),
        withdrawOnOpen: false,
        getObject: false,
        txOpts: { from: this.account.toLowerCase(), gasPrice: this.defaultGasPrice, gas: this.defaultGasAmount }
      });
      console.log(transactionReceipt);

      amountToTake = amountToTake.minus(amountShouldBeTaken);
    }
  };

  _takeAugurOrdersWithBzx = async (orders, tokenAddress) => {
    for (let e of orders) {
      console.log(`Trading augur position with bzx order ${e.loanOrderHash}`);
      console.log(tokenAddress);
      await this.bzxjs.tradePositionWithOracle({
        orderHash: e.loanOrderHash.toLowerCase(),
        tradeTokenAddress: tokenAddress.toLowerCase(),
        getObject: false,
        txOpts: { from: this.account.toLowerCase(), gasPrice: this.defaultGasPrice, gas: this.defaultGasAmount }
      });
    }
  };
}
