/* global artifacts, contract, before, it, assert, web3 */
/* eslint-disable prefer-reflect */

const Whitelist = artifacts.require('Whitelist.sol');
const BancorNetwork = artifacts.require('BancorNetwork.sol');
const ContractIds = artifacts.require('ContractIds.sol');
const BancorConverter = artifacts.require('BancorConverter.sol');
const BancorConverterFactory = artifacts.require('BancorConverterFactory.sol');
const BancorConverterUpgrader = artifacts.require('BancorConverterUpgrader.sol');
const SmartToken = artifacts.require('SmartToken.sol');
const BancorFormula = artifacts.require('BancorFormula.sol');
const BancorGasPriceLimit = artifacts.require('BancorGasPriceLimit.sol');
const ContractRegistry = artifacts.require('ContractRegistry.sol');
const ContractFeatures = artifacts.require('ContractFeatures.sol');
const EtherToken = artifacts.require('EtherToken.sol');
const TestERC20Token = artifacts.require('TestERC20Token.sol');

const ethUtil = require('ethereumjs-util');
//const web3Utils = require('web3-utils');

const BZx = artifacts.require("BZx");
const BZxProxy = artifacts.require("BZxProxy");
const BZxVault = artifacts.require("BZxVault");
const OracleRegistry = artifacts.require("OracleRegistry");
const BancorOracle = artifacts.require("BancorOracle");
const BZxProxySettings = artifacts.require("BZxProxySettings");

const Reverter = require("./utils/reverter");
const BN = require("bn.js");
const utils = require("./utils/utils.js");

const MAX_UINT = (new BN(2)).pow(new BN(256)).sub(new BN(1));
const NULL_ADDRESS = "0x0000000000000000000000000000000000000000";
const gasPrice = 22000000000;
const gasPriceBadHigh = 22000000001;

const SignatureType = Object.freeze({
    Illegal: 0,
    Invalid: 1,
    EIP712: 2,
    EthSign: 3,
    Wallet: 4,
    Validator: 5,
    PreSigned: 6
});

let token;
let tokenAddress;
let contractRegistry;
let contractIds;
let contractFeatures;
let connectorToken;
let connectorToken2;
let connectorToken3;
let connectorToken4;
let upgrader;
let converter;

contract('Bancor', accounts => {
    let reverter = new Reverter(web3);

    var bZx;
    var vault;
    var oracle;

    var loanToken;
    var collateralToken;
    var interestToken;
    var tradeToken;

    // account roles
    var owner = accounts[0];
    var lender = accounts[1];
    var trader = accounts[2];
    var maker = accounts[7];

    var order;
    var orderHash;

    before("Init bancor converter", async () => {
        contractRegistry = await ContractRegistry.new();
        contractIds = await ContractIds.new();

        contractFeatures = await ContractFeatures.new();
        let contractFeaturesId = await contractIds.CONTRACT_FEATURES.call();
        await contractRegistry.registerAddress(contractFeaturesId, contractFeatures.address);

        let gasPriceLimit = await BancorGasPriceLimit.new(gasPrice);
        let gasPriceLimitId = await contractIds.BANCOR_GAS_PRICE_LIMIT.call();
        await contractRegistry.registerAddress(gasPriceLimitId, gasPriceLimit.address);

        let formula = await BancorFormula.new();
        let formulaId = await contractIds.BANCOR_FORMULA.call();
        await contractRegistry.registerAddress(formulaId, formula.address);

        let bancorNetwork = await BancorNetwork.new(contractRegistry.address);
        let bancorNetworkId = await contractIds.BANCOR_NETWORK.call();
        await contractRegistry.registerAddress(bancorNetworkId, bancorNetwork.address);
        await bancorNetwork.setSignerAddress(accounts[3]);

        let factory = await BancorConverterFactory.new();
        let bancorConverterFactoryId = await contractIds.BANCOR_CONVERTER_FACTORY.call();
        await contractRegistry.registerAddress(bancorConverterFactoryId, factory.address);

        upgrader = await BancorConverterUpgrader.new(contractRegistry.address);
        let bancorConverterUpgraderId = await contractIds.BANCOR_CONVERTER_UPGRADER.call();
        await contractRegistry.registerAddress(bancorConverterUpgraderId, upgrader.address);

        let bancorXId = await contractIds.BANCOR_X.call();
        await contractRegistry.registerAddress(bancorXId, accounts[0])        
        
        connectorToken = await TestERC20Token.new('ERC Token 1', 'ERC1', 1000000000);
        connectorToken2 = await TestERC20Token.new('ERC Token 2', 'ERC2', 2000000000);
        connectorToken3 = await TestERC20Token.new('ERC Token 3', 'ERC3', 3500000000);
        connectorToken4 = await TestERC20Token.new('ERC Token 4', 'ERC4', 2500000000);

        token = await SmartToken.new('Token1', 'TKN1', 2);
        tokenAddress = token.address;
    
        converter = await BancorConverter.new(
            tokenAddress,
            contractRegistry.address,
            0,
            connectorToken.address,
            250000
        );

        let converterAddress = converter.address;
        await converter.addConnector(connectorToken2.address, 150000, false);
        await converter.addConnector(connectorToken3.address, 150000, false);
        await converter.addConnector(connectorToken4.address, 150000, false);
    
        await token.issue(accounts[0], 100000);
        await connectorToken.transfer(converterAddress, 80000);
        await connectorToken2.transfer(converterAddress, 80000);
        await connectorToken3.transfer(converterAddress, 80000);
        await connectorToken4.transfer(converterAddress, 80000);
            
        await token.transferOwnership(converterAddress);
        await converter.acceptTokenOwnership();
    });    
    
    before("Deploy and register bancor oracle", async () => {
        vault = await BZxVault.deployed();
        oracleRegistry = await OracleRegistry.deployed();
        bZx = await BZx.at((await BZxProxy.deployed()).address);

        oracle = await BancorOracle.new(vault.address, bZx.address, converter.address, await bZx.wethContract());

        await oracleRegistry.addOracle(oracle.address, "BancorOracle");
        assert.isTrue(await oracleRegistry.hasOracle(oracle.address));
        
        let proxySettings = await BZxProxySettings.at(bZx.address);
        await proxySettings.setOracleReference(oracle.address, oracle.address);

        assert.equal(await bZx.oracleAddresses(oracle.address), oracle.address);
    });

    before("Init loan / collateral / interest tokens", async () => {        
        loanToken = connectorToken;
        collateralToken = connectorToken2;
        interestToken = connectorToken3; 
        tradeToken = connectorToken4;

        await loanToken.transfer(lender, 1000);
        await collateralToken.transfer(trader, 1000);
        await interestToken.transfer(trader, 1000);
        await tradeToken.transfer(trader, 1000);

        await loanToken.approve(vault.address, MAX_UINT, { from: lender });
        await collateralToken.approve(vault.address, MAX_UINT, { from: trader });
        await interestToken.approve(vault.address, MAX_UINT, { from: trader });
        await tradeToken.approve(vault.address, MAX_UINT, { from: trader });
    });

    it("lender should generate and sign valid order hash", async () => {
        order = await generateTraderOrder();

        orderHash = await bZx.getLoanOrderHash.call(
            orderAddresses(order),
            orderValues(order),
            oracleData(order)
        );

        //console.log("OrderHash:", orderHash);

        let signature = await sign(lender, orderHash);
        //console.log("Signature:", signature);

        assert.isTrue(await bZx.isValidSignature(lender, orderHash, signature));
    })

    it("taker should take an order", async () => {
        let signature = await sign(lender, orderHash);

        await bZx.takeLoanOrderAsTrader(
            orderAddresses(order),
            orderValues(order),
            oracleData(order),
            collateralToken.address,
            300,
            NULL_ADDRESS,
            false,
            signature,
            {from: trader}
        );        
    })

    it("taker should trade position with oracle", async () => {
        assert.isFalse(await bZx.shouldLiquidate(orderHash, trader));
        
        let positionOffset = await bZx.getPositionOffset(orderHash, trader);
        console.log("Position offset:", positionOffset);

        // let r1 = await converter.getReturn(loanToken.address, tradeToken.address, 300);
        // console.log("loanToken -> tradeToken", r1[0], r1[1])

        // let r2 = await converter.getReturn(tradeToken.address, loanToken.address, 300);
        // console.log("loanToken -> tradeToken", r2[0], r2[1])

        let tx = await bZx.tradePositionWithOracle(orderHash, tradeToken.address, {from: trader});
        
        // let r3 = await converter.getReturn(loanToken.address, tradeToken.address, 300);
        // console.log("loanToken -> tradeToken", r3[0], r3[1])

        // let r4 = await converter.getReturn(tradeToken.address, loanToken.address, 300);
        // console.log("loanToken -> tradeToken", r4[0], r4[1])
    });

    it("should close loan as (trader)", async () => {
        await reverter.snapshot();
    
        await bZx.closeLoan(orderHash, { from: trader });
        
        await reverter.revert();
    });
    
    it("should liquidate position", async () => {
        await reverter.snapshot();

        await bZx.liquidatePosition(orderHash, trader, { from: lender });
            
        await reverter.revert();
    });
    
    it("should force close loan", async () => {
        await reverter.snapshot();

        await bZx.forceCloanLoan(orderHash, trader, {from: owner});
    
        await reverter.revert();
    });

    function toHex(d) {
        return ("0" + Number(d).toString(16)).slice(-2).toUpperCase();
    }

    let sign = async (signer, data) => {
        let signature = await web3.eth.sign(data, signer) + toHex(SignatureType.EthSign);
        assert.isOk(await bZx.isValidSignature.call(signer, data, signature));
        return signature;
    };

    let oracleData = (order) => {
        return "0x00";
    }

    let orderAddresses = (order) => {
        return [
            order["makerAddress"],
            order["loanTokenAddress"],
            order["interestTokenAddress"],
            order["collateralTokenAddress"],
            order["feeRecipientAddress"],
            order["oracleAddress"],
            order["takerAddress"],
            order["tradeTokenToFillAddress"]
        ]
    }

    let orderValues = (order) => {
        return [
            new BN(order["loanTokenAmount"]),
            new BN(order["interestAmount"]),
            new BN(order["initialMarginAmount"]),
            new BN(order["maintenanceMarginAmount"]),
            new BN(order["lenderRelayFee"]),
            new BN(order["traderRelayFee"]),
            new BN(order["maxDurationUnixTimestampSec"]),
            new BN(order["expirationUnixTimestampSec"]),
            new BN(order["makerRole"]),
            new BN(order["withdrawOnOpen"]),
            new BN(order["salt"])
        ]
    }

    let generateTraderOrder = async () => {
        let traderOrder = {
            bZxAddress: bZx.address,
            makerAddress: lender, // lender
            loanTokenAddress: loanToken.address,
            interestTokenAddress: interestToken.address,
            collateralTokenAddress: utils.zeroAddress,
            feeRecipientAddress: utils.zeroAddress,
            oracleAddress: oracle.address,
            loanTokenAmount: "3000",
            interestAmount: "200", // 2 token units per day
            initialMarginAmount: utils.toWei(50, "ether").toString(), // 50%
            maintenanceMarginAmount: utils.toWei(5, "ether").toString(), // 25%
            lenderRelayFee: utils.toWei(0.000, "ether").toString(),
            traderRelayFee: utils.toWei(0.0, "ether").toString(),
            maxDurationUnixTimestampSec: "2419200", // 28 days
            expirationUnixTimestampSec: ((await web3.eth.getBlock("latest")).timestamp + 86400).toString(),
            makerRole: "0", // 0=lender, 1=trader
            salt: "random_string",
            takerAddress: NULL_ADDRESS,
	        tradeTokenToFillAddress: NULL_ADDRESS,
            withdrawOnOpen: "0"
        }

        return traderOrder;
    }
});