/**
 * Copyright 2017–2018, bZeroX, LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0.
 */

pragma solidity 0.4.24;

pragma experimental ABIEncoderV2;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";

import "./IAugurNetworkAdapter.sol";
import "../OracleInterface.sol";

import "../../modifiers/EMACollector.sol";
import "../../modifiers/GasRefunder.sol";
import "../../modifiers/BZxOwnable.sol";
import "../../shared/WETHInterface.sol";
import "../../storage/BZxObjects.sol";
import "../../tokens/EIP20.sol";
import "../../tokens/EIP20Wrapper.sol";
import "../../BZx.sol";

contract AugurOracle is BZxOwnable, OracleInterface, EIP20Wrapper, EMACollector, GasRefunder {
    using SafeMath for uint256;

    // this is the value the Kyber portal uses when setting a very high maximum number
    uint internal constant MAX_FOR_KYBER = 57896044618658097711785492504343953926634992332820282019728792003956564819968;

    mapping (address => uint) internal decimals;

    // Bounty hunters are remembursed from collateral
    // The oracle requires a minimum amount
    uint public minimumCollateralInWethAmount = 0.5 ether;

    // If true, the collateral must not be below minimumCollateralInWethAmount for the loan to be opened
    // If false, the loan can be opened, but it won't be insured by the insurance fund if collateral is below minimumCollateralInWethAmount
    bool public enforceMinimum = false;

    // Percentage of interest retained as fee
    // This will always be between 0 and 100
    uint public interestFeePercent = 10;

    // Percentage of EMA-based gas refund paid to bounty hunters after successfully liquidating a position
    uint public bountyRewardPercent = 110;

    // An upper bound estimation on the liquidation gas cost
    uint public gasUpperBound = 600000;

    // A threshold of minimum initial margin for loan to be insured by the guarantee fund
    // A value of 0 indicates that no threshold exists for this parameter.
    uint public minInitialMarginAmount = 0;

    // A threshold of minimum maintenance margin for loan to be insured by the guarantee fund
    // A value of 0 indicates that no threshold exists for this parameter.
    uint public minMaintenanceMarginAmount = 25;

    address public vault;
    address public weth;
    IAugurNetworkAdapter public augurNetwork;

    mapping (uint => uint) public collateralInWethAmounts; // mapping of position ids to initial collateralInWethAmounts
    mapping (bytes32 => mapping (address => bool)) public allowedMarkets;

    constructor(
        address _vault,                
        address _bZxContractAddress,
        address _wethContract,
        address _augurNetwork)
    public {
        vault = _vault;
        bZxContractAddress = _bZxContractAddress;
        weth = _wethContract;
        augurNetwork = IAugurNetworkAdapter(_augurNetwork);

        // settings for EMACollector
        emaValue = 8 * 10**9 wei; // set an initial price average for gas (8 gwei)
        emaPeriods = 10; // set periods to use for EMA calculation
    }

    // TODO: just for test, REMOVE ME
    function init(
        address _vault,                
        address _bZxContractAddress,
        address _wethContract,
        address _augurNetwork) 
    public {        
        vault = _vault;
        bZxContractAddress = _bZxContractAddress;
        weth = _wethContract;
        augurNetwork = IAugurNetworkAdapter(_augurNetwork);

        emaValue = 8 * 10**9 wei; // set an initial price average for gas (8 gwei)
        emaPeriods = 10; // set periods to use for EMA calculation

        minMaintenanceMarginAmount = 25;
        minInitialMarginAmount = 0;
        gasUpperBound = 600000;
        bountyRewardPercent = 110;
        interestFeePercent = 10;
        enforceMinimum = false;
        minimumCollateralInWethAmount = 0.5 ether;        
    }  

   function didAddOrder(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanOrderAux loanOrderAux,
        bytes oracleData,
        address taker,
        uint gasUsed)
    public 
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        if (oracleData.length == 0) {
            return false;
        }

        address[] memory markets = parseAddresses(oracleData);
        bytes32 loanOrderHash = loanOrder.loanOrderHash;
        
        for (uint idx = 0; idx < markets.length; idx++ ) {
            allowedMarkets[loanOrderHash][markets[idx]] = true;
        }
        
        return true;
    }

    function isMarketAllowed(bytes32 _orderhash, address _market) 
    public
    view
    returns (bool) {
        return allowedMarkets[_orderhash][_market];
    }

    function allowMarketTrading(bytes32 _orderHash, address[] _markets)
    public
    returns (bool) {
        require(_orderHash != bytes32(0x0), "AugurOracle::allowMarketTrading: Invalid order hash");
        require(_markets.length > 0, "AugurOracle::allowMarketTrading: Markets list is empty");

        BZxObjects.LoanOrderAux memory orderAux = BZx(bZxContractAddress).getLoanOrderAux(_orderHash);

        // TODO: ahiatsevich: should trader be permitted to change markets?        
        if (orderAux.maker != msg.sender) {
            return false;
        }

        for (uint i = 0; i < _markets.length; i++) {
            allowedMarkets[_orderHash][_markets[i]] = true;
        }

        return true;
    }

    function didTakeOrder(BZxObjects.LoanOrder memory, BZxObjects.LoanOrderAux, BZxObjects.LoanPosition loanPosition, address, uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        uint collateralInWethAmount;
        if (loanPosition.collateralTokenAddressFilled != weth) {
            (uint ethToCollateralRate,) = _getExpectedRate(
                weth,
                loanPosition.collateralTokenAddressFilled,
                0
            );
            collateralInWethAmount = loanPosition.collateralTokenAmountFilled.mul(_getDecimalPrecision(weth, loanPosition.collateralTokenAddressFilled)).div(ethToCollateralRate);
        } else {
            collateralInWethAmount = loanPosition.collateralTokenAmountFilled;
        }

        require(!enforceMinimum || collateralInWethAmount >= minimumCollateralInWethAmount, "collateral below minimum for AugurOracle");
        collateralInWethAmounts[loanPosition.positionId] = collateralInWethAmount;

        return true;
    }

    function didTradePosition(BZxObjects.LoanOrder memory loanOrder, BZxObjects.LoanPosition memory loanPosition, uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        require (
            getCurrentMarginAmount(
                loanOrder.loanTokenAddress,
                loanPosition.positionTokenAddressFilled,
                loanPosition.collateralTokenAddressFilled,
                loanPosition.loanTokenAmountFilled,
                loanPosition.positionTokenAmountFilled,
                loanPosition.collateralTokenAmountFilled) > loanOrder.maintenanceMarginAmount.mul(10**18),
            "AugurOracle::didTradePosition: trade triggers liquidation"
        );

        return true;
    }

    function didPayInterest(BZxObjects.LoanOrder memory loanOrder, address lender, uint amountOwed, bool convert, uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        // interestFeePercent is only editable by owner
        uint interestFee = amountOwed.mul(interestFeePercent).div(100);

        // Transfers the interest to the lender, less the interest fee.
        // The fee is retained by the oracle.
        require(eip20Transfer(
                    loanOrder.interestTokenAddress,
                    lender,
                    amountOwed.sub(interestFee)), 
                "AugurOracle::didPayInterest: eip20Transfer failed");

        if (convert && loanOrder.interestTokenAddress != weth) {
            // interest paid in WETH or BZRX is retained as is, other tokens are sold for WETH
            _doTradeForWeth(
                loanOrder.interestTokenAddress,
                interestFee,
                this, // AugurOracle receives the WETH proceeds
                MAX_FOR_KYBER // no limit on the dest amount
            );
        }

        return true;
    }

    function didDepositCollateral(BZxObjects.LoanOrder memory, BZxObjects.LoanPosition memory, uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didWithdrawCollateral(BZxObjects.LoanOrder memory, BZxObjects.LoanPosition memory, uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didChangeCollateral(BZxObjects.LoanOrder memory, BZxObjects.LoanPosition memory, uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didWithdrawProfit(BZxObjects.LoanOrder memory, BZxObjects.LoanPosition memory, uint, uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didCloseLoan(
        BZxObjects.LoanOrder memory /* loanOrder */,
        BZxObjects.LoanPosition memory /* loanPosition */,
        address loanCloser,
        bool isLiquidation,
        uint gasUsed)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        // sends gas and bounty reward to bounty hunter
        if (isLiquidation) {
            (uint refundAmount, uint finalGasUsed) = getGasRefund(
                gasUsed,
                emaValue,
                bountyRewardPercent
            );

            if (refundAmount > 0) {
                // refunds are paid in ETH
                uint wethBalance = EIP20(weth).balanceOf.gas(4999)(this);
                if (refundAmount > wethBalance)
                    refundAmount = wethBalance;

                WETHInterface(weth).withdraw(refundAmount);

                sendGasRefund(loanCloser, refundAmount, finalGasUsed, emaValue);
            }
        }

        return true;
    }
    
    function didChangeTraderOwnership(BZxObjects.LoanOrder memory, BZxObjects.LoanPosition memory, address, uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didChangeLenderOwnership(BZxObjects.LoanOrder memory, address, address, uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didIncreaseLoanableAmount(BZxObjects.LoanOrder memory, address, uint, uint, uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function doManualTrade(address sourceTokenAddress, address destTokenAddress, uint sourceTokenAmount)
    public
    returns (uint) {
        return doTrade(sourceTokenAddress, destTokenAddress, sourceTokenAmount);
    }

    function doTrade(
        address sourceTokenAddress,
        address destTokenAddress,
        uint sourceTokenAmount)
    public
    onlyBZx
    returns (uint destTokenAmount) {
        destTokenAmount = _doTrade(
            sourceTokenAddress,
            destTokenAddress,
            sourceTokenAmount,
            MAX_FOR_KYBER); // no limit on the dest amount
    }

    function verifyAndLiquidate(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition)
    public
    onlyBZx
    returns (uint destTokenAmount) {
        if (!shouldLiquidate(
            0x0,
            0x0,
            loanOrder.loanTokenAddress,
            loanPosition.positionTokenAddressFilled,
            loanPosition.collateralTokenAddressFilled,
            loanPosition.loanTokenAmountFilled,
            loanPosition.positionTokenAmountFilled,
            loanPosition.collateralTokenAmountFilled,
            loanOrder.maintenanceMarginAmount)) {
            return 0;
        }

        destTokenAmount = _doTrade(
            loanPosition.positionTokenAddressFilled,
            loanOrder.loanTokenAddress,
            loanPosition.positionTokenAmountFilled,
            MAX_FOR_KYBER); // no limit on the dest amount
    }

    // note: bZx will only call this function if isLiquidation=true or loanTokenAmountNeeded > 0
    function processCollateral(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition,
        uint loanTokenAmountNeeded,
        bool isLiquidation) 
    public
    onlyBZx
    returns (uint loanTokenAmountCovered, uint collateralTokenAmountUsed) {
        require(isLiquidation || loanTokenAmountNeeded > 0, "!isLiquidation && loanTokenAmountNeeded == 0");

        uint collateralTokenBalance = EIP20(loanPosition.collateralTokenAddressFilled).balanceOf.gas(4999)(this); // Changes to state require at least 5000 gas
        if (collateralTokenBalance < loanPosition.collateralTokenAmountFilled) { // sanity check
            revert("AugurOracle::processCollateral: collateralTokenBalance < loanPosition.collateralTokenAmountFilled");
        }

        uint wethAmountReceived = _getWethFromCollateral(
            loanPosition.collateralTokenAddressFilled,
            loanOrder.loanTokenAddress,
            loanPosition.collateralTokenAmountFilled,
            loanTokenAmountNeeded,
            isLiquidation
        );

        if (loanTokenAmountNeeded > 0) {
            if (collateralInWethAmounts[loanPosition.positionId] >= minimumCollateralInWethAmount && 
                (minInitialMarginAmount == 0 || loanOrder.initialMarginAmount >= minInitialMarginAmount) &&
                (minMaintenanceMarginAmount == 0 || loanOrder.maintenanceMarginAmount >= minMaintenanceMarginAmount)) {
                // cover losses with collateral proceeds + oracle insurance
                loanTokenAmountCovered = _doTradeWithWeth(
                    loanOrder.loanTokenAddress,
                    MAX_FOR_KYBER, // maximum usable amount
                    vault,
                    loanTokenAmountNeeded
                );
            } else {
                // cover losses with just collateral proceeds
                loanTokenAmountCovered = _doTradeWithWeth(
                    loanOrder.loanTokenAddress,
                    wethAmountReceived, // maximum usable amount
                    vault,
                    loanTokenAmountNeeded
                );
            }
        }

        collateralTokenAmountUsed = collateralTokenBalance.sub(EIP20(loanPosition.collateralTokenAddressFilled).balanceOf.gas(4999)(this)); // Changes to state require at least 5000 gas

        if (collateralTokenAmountUsed < loanPosition.collateralTokenAmountFilled) {
            // send unused collateral token back to the vault
            if (!eip20Transfer(
                loanPosition.collateralTokenAddressFilled,
                vault,
                loanPosition.collateralTokenAmountFilled-collateralTokenAmountUsed)) {
                revert("AugurOracle::processCollateral: eip20Transfer failed");
            }
        }
    }

    /*
    * Public View functions
    */

    function shouldLiquidate(
        bytes32 /* loanOrderHash */,
        address /* trader */,
        address loanTokenAddress,
        address positionTokenAddress,
        address collateralTokenAddress,
        uint loanTokenAmount,
        uint positionTokenAmount,
        uint collateralTokenAmount,
        uint maintenanceMarginAmount)
    public
    view
    returns (bool) {
        return (
            getCurrentMarginAmount(
                loanTokenAddress,
                positionTokenAddress,
                collateralTokenAddress,
                loanTokenAmount,
                positionTokenAmount,
                collateralTokenAmount) <= maintenanceMarginAmount.mul(10**18)
            );
    }

    function isTradeSupported(address src, address dest, uint srcAmount)
    public
    view
    returns (bool) {
        (uint rate, uint slippage) = _getExpectedRate(src, dest, srcAmount);        
        return rate > 0 || slippage > 0;
    }

    function getTradeData(address src, address dest, uint srcAmount)
    public
    view
    returns (uint srcToDestRate, uint destTokenAmount) {
        (srcToDestRate,) = _getExpectedRate(src, dest, srcAmount);
        destTokenAmount = srcAmount.mul(srcAmount).div(_getDecimalPrecision(src, dest));
    }

    // returns bool isProfit, uint profitOrLoss
    // the position's profit/loss denominated in positionToken
    function getProfitOrLoss(
        address positionTokenAddress,
        address loanTokenAddress,
        uint positionTokenAmount,
        uint loanTokenAmount)
    public
    view
    returns (bool isProfit, uint profitOrLoss) {
        uint loanToPositionAmount;
        if (positionTokenAddress == loanTokenAddress) {
            loanToPositionAmount = loanTokenAmount;
        } else {
            (uint positionToLoanRate,) = _getExpectedRate(
                positionTokenAddress,
                loanTokenAddress,
                0);
            if (positionToLoanRate == 0) {
                return;
            }
            loanToPositionAmount = loanTokenAmount.mul(_getDecimalPrecision(positionTokenAddress, loanTokenAddress)).div(positionToLoanRate);
        }

        if (positionTokenAmount > loanToPositionAmount) {
            isProfit = true;
            profitOrLoss = positionTokenAmount - loanToPositionAmount;
        } else {
            isProfit = false;
            profitOrLoss = loanToPositionAmount - positionTokenAmount;
        }
    }

    /// @return The current margin amount (a percentage -> i.e. 54350000000000000000 == 54.35%)
    function getCurrentMarginAmount(
        address loanTokenAddress,
        address positionTokenAddress,
        address collateralTokenAddress,
        uint loanTokenAmount,
        uint positionTokenAmount,
        uint collateralTokenAmount)
    public
    view
    returns (uint) {
        uint collateralToLoanAmount;
        if (collateralTokenAddress == loanTokenAddress) {
            collateralToLoanAmount = collateralTokenAmount;
        } else {
            (uint collateralToLoanRate,) = _getExpectedRate(
                collateralTokenAddress,
                loanTokenAddress,
                0);
            if (collateralToLoanRate == 0) {
                return 0;
            }
            collateralToLoanAmount = collateralTokenAmount.mul(collateralToLoanRate).div(_getDecimalPrecision(collateralTokenAddress, loanTokenAddress));
        }

        uint positionToLoanAmount;
        if (positionTokenAddress == loanTokenAddress) {
            positionToLoanAmount = positionTokenAmount;
        } else {
            (uint positionToLoanRate,) = _getExpectedRate(
                positionTokenAddress,
                loanTokenAddress,
                0);
            if (positionToLoanRate == 0) {
                return 0;
            }
            positionToLoanAmount = positionTokenAmount.mul(positionToLoanRate).div(_getDecimalPrecision(positionTokenAddress, loanTokenAddress));
        }

        return collateralToLoanAmount.add(positionToLoanAmount).sub(loanTokenAmount).mul(10**20).div(loanTokenAmount);
    }

    /*
    * Owner functions
    */

    function setDecimals(EIP20 token)
    public
    onlyOwner {
        decimals[token] = token.decimals();
    }

    function setDecimalsBatch(EIP20[] tokens)
    public 
    onlyOwner {
        for(uint i = 0; i < tokens.length; i++) {
            decimals[tokens[i]] = tokens[i].decimals();
        }
    }

    function setMinimumCollateralInWethAmount(uint newValue, bool enforce)
    public
    onlyOwner {
        if (newValue != minimumCollateralInWethAmount)
            minimumCollateralInWethAmount = newValue;

        if (enforce != enforceMinimum)
            enforceMinimum = enforce;
    }

    function setInterestFeePercent(uint newRate)
    public
    onlyOwner {
        require(newRate != interestFeePercent && newRate <= 100);
        interestFeePercent = newRate;
    }

    function setBountyRewardPercent(uint newValue)
    public
    onlyOwner {
        require(newValue != bountyRewardPercent);
        bountyRewardPercent = newValue;
    }

    function setGasUpperBound(uint newValue)
    public
    onlyOwner {
        require(newValue != gasUpperBound);
        gasUpperBound = newValue;
    }

    function setMarginThresholds(uint newInitialMargin, uint newMaintenanceMargin)
    public
    onlyOwner {
        require(newInitialMargin >= newMaintenanceMargin);
        minInitialMarginAmount = newInitialMargin;
        minMaintenanceMarginAmount = newMaintenanceMargin;
    }

    function setvaultAddress(address newAddress)
    public
    onlyOwner {
        require(newAddress != vault && newAddress != address(0));
        vault = newAddress;
    }

    function setEMAValue(uint _newEMAValue)
    public
    onlyOwner {
        require(_newEMAValue != emaValue);
        emaValue = _newEMAValue;
    }

    function setEMAPeriods(uint _newEMAPeriods)
    public
    onlyOwner {
        require(_newEMAPeriods > 1 && _newEMAPeriods != emaPeriods);
        emaPeriods = _newEMAPeriods;
    }

    function transferEther(address to, uint value)
    public
    onlyOwner
    returns (bool) {
        return _transferEther(to,value);
    }

    function transferToken(address tokenAddress, address to, uint value)
    public
    onlyOwner
    returns (bool) {
        return eip20Transfer(tokenAddress , to, value);
    }

    function isWETHToken(address _token)
    public 
    view
    returns (bool) {
        return _token == weth;
    }

    /*
    * Internal functions
    */

    function _getWethFromCollateral(
        address collateralTokenAddress,
        address loanTokenAddress,
        uint collateralTokenAmountUsable,
        uint loanTokenAmountNeeded,
        bool isLiquidation)
    internal
    returns (uint wethAmountReceived) {
        uint wethAmountNeeded = 0;

        if (loanTokenAmountNeeded > 0) {
            if (isWETHToken(loanTokenAddress)) {
                wethAmountNeeded = loanTokenAmountNeeded;
            } else {
                (uint wethToLoan,) = _getExpectedRate(weth, loanTokenAddress, 0);
                wethAmountNeeded = loanTokenAmountNeeded.mul(_getDecimalPrecision(weth, loanTokenAddress)).div(wethToLoan);
            }
        }

        // trade collateral token for WETH
        wethAmountReceived = _doTradeForWeth(
            collateralTokenAddress,
            collateralTokenAmountUsable,
            this, // AugurOracle receives the WETH proceeds
            !isLiquidation ? wethAmountNeeded : wethAmountNeeded.add(gasUpperBound.mul(emaValue).mul(bountyRewardPercent).div(100))
        );
    }

    function _getDecimalPrecision(address src, address dest)
    internal
    view
    returns(uint) {
        uint srcDecimals = decimals[src] != 0 ? decimals[src] : EIP20(src).decimals();            
        uint destDecimals = decimals[dest] != 0 ? decimals[dest] : EIP20(dest).decimals();
        
        return (destDecimals >= srcDecimals)
            ? 10**(SafeMath.sub(18, destDecimals - srcDecimals))
            : 10**(SafeMath.add(18, srcDecimals - destDecimals));
    }
    
    function _getExpectedRate(address src, address dest, uint srcAmount)
    internal
    view
    returns (uint expectedRate, uint slippageRate) {
        if (src == dest) {
            return (10**18, 0);
        }

        return augurNetwork.getExpectedRate(src, dest, srcAmount,3);
    }

    function _doTrade(address src, address dest, uint srcAmount, uint maxDestAmount)
    internal
    returns (uint destTokenAmount) {
        if (src == dest) {
            destTokenAmount = (maxDestAmount < srcAmount) ? maxDestAmount : srcAmount;
            require(eip20Transfer(dest, vault, destTokenAmount), "AugurOracle::_doTrade: eip20Transfer failed");
        } else {
            var (, worstPrice) = augurNetwork.getExpectedRate(src, dest, srcAmount, 3);
            uint result;
            (result, destTokenAmount) = augurNetwork.trade(src, srcAmount, dest, maxDestAmount, worstPrice, vault, 3);
            if (result != augurNetwork.OK()) {
                revert("AugurOracle::_doTrade: trade failed");
            }
        }
    }

    function _doTradeForWeth(
        address src,
        uint srcAmount,
        address receiver,
        uint destWethAmountNeeded)
    internal
    returns (uint destWethAmountReceived) {
        if (isWETHToken(src)) {
            if (destWethAmountNeeded > srcAmount) {
                destWethAmountNeeded = srcAmount;
            }
                
            if (receiver != address(this)) {
                require(eip20Transfer(weth, receiver, destWethAmountNeeded), "AugurOracle::_doTradeForWeth: eip20Transfer failed");
            }

            return destWethAmountNeeded;
        }

        bool result = address(this).call(
            bytes4(keccak256("trade(address,uint,address,uint,uint,address)")),
            src, srcAmount, weth, destWethAmountNeeded, 0, receiver);

        assembly {
            switch result
            case 0 {
                destWethAmountReceived := 0
            }
            default {
                returndatacopy(0, 0, 0x20) 
                destWethAmountReceived := mload(0)
            }
        }
    }

    function _doTradeWithWeth(
        address dest,
        uint wethAmount,
        address receiver,
        uint destAmountNeeded)
    internal
    returns (uint destTokenAmountReceived) {
        uint wethBalance = EIP20(weth).balanceOf.gas(4999)(this);

        if (isWETHToken(dest)) {
            if (destAmountNeeded > wethAmount) {
                destAmountNeeded = wethAmount;
            }
                
            if (destAmountNeeded > wethBalance) {
                destAmountNeeded = wethBalance;
            }
                
            if (receiver != address(this)) {
                require(eip20Transfer(weth, receiver, destAmountNeeded), "AugurOracle::_doTradeWithWeth: eip20Transfer failed");
            }

            return destAmountNeeded;
        }
        
        if (wethAmount > wethBalance) {
            wethAmount = wethBalance;
        }

        bool result = address(this).call(
            bytes4(keccak256("trade(address,uint,address,uint,uint,address)")),
            weth, wethAmount, dest, destAmountNeeded, 0, receiver);

        assembly {
            switch result
            case 0 {
                destTokenAmountReceived := 0
            }
            default {
                returndatacopy(0, 0, 0x20) 
                destTokenAmountReceived := mload(0)
            }
        }
    }

    function _transferEther(address to, uint value)
    internal
    returns (bool) {
        return to.send(value);
    }

    function parseAddresses(bytes data)
    public
    view
    returns (address[] result) {
        uint len = data.length;
        uint size = len / 20;

        result = new address[](size);
        for (uint idx = 0; idx < size; idx++) {
            address addr;
            assembly {
                addr := mload(add(data, mul(20, add(idx,1))))            
            }
            result[idx] = addr;
        }
    }
}
