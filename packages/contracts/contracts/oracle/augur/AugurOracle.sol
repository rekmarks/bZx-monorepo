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

    // todo: remove
    uint internal constant MAX_FOR_KYBER = 57896044618658097711785492504343953926634992332820282019728792003956564819968;    

    // todo: remove
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

    mapping (uint => uint) public collateralInWethAmounts; // todo: remove
    mapping (bytes32 => mapping (address => bool)) public allowedMarkets;  

    constructor(
        address _vault,                
        address _bZxContractAddress,
        address _wethContract,
        address _augurNetwork)
    public {
        require(_vault != address(0x0), "AugurOracle::constructor: Invalid vault address");
        require(_bZxContractAddress != address(0x0), "AugurOracle::constructor: Invalid bZx address");
        require(_wethContract != address(0x0), "AugurOracle::constructor: Invalid weth address");
        require(_augurNetwork != address(0x0), "AugurOracle::constructor: Invalid Augur network address");

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
    public
    onlyOwner {        
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
        // check interest tokens: only weth is supported
        if (loanOrder.interestTokenAddress != weth) {
            return false;
        }

        // allowed markets should be specified
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

    function didTakeOrder(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanOrderAux, 
        BZxObjects.LoanPosition loanPosition, 
        address, 
        uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        // only weth is accepted as a collateral
        if (loanPosition.collateralTokenAddressFilled != weth) {
            return false;
        }
        
        // make sure that a collateral amount is enough for this oracle
        if (enforceMinimum && loanPosition.collateralTokenAmountFilled >= minimumCollateralInWethAmount) {
            return false;
        }
            
        return true;
    }

    function didTradePosition(BZxObjects.LoanOrder memory loanOrder, BZxObjects.LoanPosition memory loanPosition, uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        // make sure that a trade is permitted by maker
        address positionToken = loanPosition.positionTokenAddressFilled;
        address loadToken = loanOrder.loanTokenAddress;

        address shareToken = isWETHToken(positionToken) ? loadToken : positionToken;

        address market = IShareToken(shareToken).getMarket();
        bytes32 orderHash = loanOrder.loanOrderHash;

        if (!allowedMarkets[orderHash][market]) {
            return false;
        }

        // make sure that an order is still valid
        if (_shouldLiquidate(loanOrder, loanPosition)) {
            return false;
        }

        return true;
    }

    function didPayInterest(BZxObjects.LoanOrder memory loanOrder, address lender, uint amountOwed, bool, uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        // InterestFeePercent is only editable by owner
        uint interestFee = amountOwed.mul(interestFeePercent).div(100);

        // Transfers the interest to the lender, less the interest fee.
        // The fee is retained by the oracle.
        return EIP20(loanOrder.interestTokenAddress).transfer(lender, amountOwed.sub(interestFee));
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
                if (refundAmount > wethBalance) {
                    refundAmount = wethBalance;
                }                    

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

    function doManualTrade(address src, address dest, uint srcAmount)
    public
    returns (uint) {
        return doTrade(src, dest, srcAmount);
    }

    function doTrade(address src, address dest, uint srcAmount)
    public
    onlyBZx
    returns (uint) {
        // make sure that the oracle have received enough src token to do a trade
        require(EIP20(src).balanceOf(address(this)) >= srcAmount, "AugurOracle::_doTrade: Src token balance is not enough");

        // weth and augur share token are not protected against double spend attack 
        // no need to set allowance to 0
        require(EIP20(src).approve(augurNetwork, srcAmount), "AugurOracle::_doTrade: Unable to set allowance");

        var (rate, worstRate) = augurNetwork.getExpectedRate(src, dest, srcAmount, 1);

        uint result;
        uint destToken;

        // a rate always shows how much weth should be spent to buy 1 share token, i.e rate = weth/share_token
        if (src == weth) {
            (result, destToken) = augurNetwork.trade(src, srcAmount, dest, srcAmount.div(rate), worstRate, vault, 1);
        } else {
            assert(dest == weth);
            (result, destToken) = augurNetwork.trade(src, srcAmount, dest, srcAmount.mul(rate), worstRate, vault, 1);
        }
        
        require(result == augurNetwork.OK(), "AugurOracle::_doTrade: trade failed");

        return destToken;
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

        return doTrade(
            loanPosition.positionTokenAddressFilled,
            loanOrder.loanTokenAddress,
            loanPosition.positionTokenAmountFilled);
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
        require(isLiquidation || loanTokenAmountNeeded > 0, "AugurOracle::processCollateral: !isLiquidation && loanTokenAmountNeeded == 0");
        require(loanPosition.collateralTokenAddressFilled == weth, "AugurOracle::processCollateral: Invalid state, only weth is accepted as a collateral");

        // collateralTokenAddressFilled == weth
        uint collateralTokenBalance = EIP20(loanPosition.collateralTokenAddressFilled).balanceOf(this);
        require(collateralTokenBalance >= loanPosition.collateralTokenAmountFilled,
            "AugurOracle::processCollateral: collateralTokenBalance < loanPosition.collateralTokenAmountFilled");
   
        // if (loanTokenAmountNeeded > 0) {
        //     if (collateralInWethAmounts[loanPosition.positionId] >= minimumCollateralInWethAmount && 
        //         (minInitialMarginAmount == 0 || loanOrder.initialMarginAmount >= minInitialMarginAmount) &&
        //         (minMaintenanceMarginAmount == 0 || loanOrder.maintenanceMarginAmount >= minMaintenanceMarginAmount)) {
        //         // cover losses with collateral proceeds + oracle insurance
        //         loanTokenAmountCovered = _doTradeWithWeth(
        //             loanOrder.loanTokenAddress,
        //             MAX_FOR_KYBER, // maximum usable amount
        //             vault,
        //             loanTokenAmountNeeded
        //         );
        //     } else {
        //         // cover losses with just collateral proceeds
        //         loanTokenAmountCovered = _doTradeWithWeth(
        //             loanOrder.loanTokenAddress,
        //             wethAmountReceived, // maximum usable amount
        //             vault,
        //             loanTokenAmountNeeded
        //         );
        //     }
        // }

        // collateralTokenAmountUsed = collateralTokenBalance.sub(EIP20(loanPosition.collateralTokenAddressFilled).balanceOf.gas(4999)(this)); // Changes to state require at least 5000 gas

        // if (collateralTokenAmountUsed < loanPosition.collateralTokenAmountFilled) {
        //     // send unused collateral token back to the vault
        //     if (!eip20Transfer(
        //         loanPosition.collateralTokenAddressFilled,
        //         vault,
        //         loanPosition.collateralTokenAmountFilled-collateralTokenAmountUsed)) {
        //         revert("AugurOracle::processCollateral: eip20Transfer failed");
        //     }
        // }

        return (0, 0);
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
        return false;
        // return (
        //     getCurrentMarginAmount(
        //         loanTokenAddress,
        //         positionTokenAddress,
        //         collateralTokenAddress,
        //         loanTokenAmount,
        //         positionTokenAmount,
        //         collateralTokenAmount) <= maintenanceMarginAmount.mul(10**18)
        //     );
    }

    function isTradeSupported(address src, address dest, uint srcAmount)
    public
    view
    returns (bool) {        
        return true;
    }

    function getTradeData(address src, address dest, uint srcAmount)
    public
    view
    returns (uint srcToDestRate, uint destTokenAmount) {
        (srcToDestRate,) = getExpectedRate(src, dest, srcAmount);
        destTokenAmount = srcAmount.mul(srcToDestRate).div(10**18);
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
        // uint loanToPositionAmount;
        // if (positionTokenAddress == loanTokenAddress) {
        //     loanToPositionAmount = loanTokenAmount;
        // } else {
        //     (uint positionToLoanRate,) = getExpectedRate(
        //         positionTokenAddress,
        //         loanTokenAddress,
        //         0);
        //     if (positionToLoanRate == 0) {
        //         return;
        //     }
        //     loanToPositionAmount = loanTokenAmount.mul(_getDecimalPrecision(positionTokenAddress, loanTokenAddress)).div(positionToLoanRate);
        // }

        // if (positionTokenAmount > loanToPositionAmount) {
        //     isProfit = true;
        //     profitOrLoss = positionTokenAmount - loanToPositionAmount;
        // } else {
        //     isProfit = false;
        //     profitOrLoss = loanToPositionAmount - positionTokenAmount;
        // }

        return (true, 0);
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
        // uint collateralToLoanAmount;
        // if (collateralTokenAddress == loanTokenAddress) {
        //     collateralToLoanAmount = collateralTokenAmount;
        // } else {
        //     (uint collateralToLoanRate,) = getExpectedRate(
        //         collateralTokenAddress,
        //         loanTokenAddress,
        //         0);
        //     if (collateralToLoanRate == 0) {
        //         return 0;
        //     }
        //     collateralToLoanAmount = collateralTokenAmount.mul(collateralToLoanRate).div(_getDecimalPrecision(collateralTokenAddress, loanTokenAddress));
        // }

        // uint positionToLoanAmount;
        // if (positionTokenAddress == loanTokenAddress) {
        //     positionToLoanAmount = positionTokenAmount;
        // } else {
        //     (uint positionToLoanRate,) = getExpectedRate(
        //         positionTokenAddress,
        //         loanTokenAddress,
        //         0);
        //     if (positionToLoanRate == 0) {
        //         return 0;
        //     }
        //     positionToLoanAmount = positionTokenAmount.mul(positionToLoanRate).div(_getDecimalPrecision(positionTokenAddress, loanTokenAddress));
        // }

        // return collateralToLoanAmount.add(positionToLoanAmount).sub(loanTokenAmount).mul(10**20).div(loanTokenAmount);

        return 0;
    }

    /*
    * Owner functions
    */

    function setMinimumCollateralInWethAmount(uint newValue, bool enforce)
    public
    onlyOwner {
        if (newValue != minimumCollateralInWethAmount) {
            minimumCollateralInWethAmount = newValue;
        }   

        if (enforce != enforceMinimum) {
            enforceMinimum = enforce;
        }            
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

    function setVaultAddress(address newAddress)
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
        return to.send(value);
    }

    function transferToken(address tokenAddress, address to, uint value)
    public
    onlyOwner
    returns (bool) {
        return eip20Transfer(tokenAddress , to, value);
    }

    /*
    * Aux functions
    */

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
    
    function getExpectedRate(address src, address dest, uint srcAmount)
    public
    view
    returns (uint expectedRate, uint slippageRate) {
        uint RATE_COEFF = 10**18;

        if (src != weth && dest != weth) {
            return (0, 0);
        }
        
        if (src == dest) {
            return (1 * RATE_COEFF, 1 * RATE_COEFF);
        }
        
        var (rate, slippage) = augurNetwork.getExpectedRate(src, dest, srcAmount, 1);

        if (src == weth) {
            return (rate.mul(RATE_COEFF), slippage.mul(RATE_COEFF));
        } else if (dest == weth) {
            return (RATE_COEFF.div(rate), RATE_COEFF.div(slippage));
        }
    }

    function isWETHToken(address _token)
    public 
    view
    returns (bool) {
        return _token == weth;
    }

    function parseAddresses(bytes data)
    public
    pure
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

    function _shouldLiquidate(
        BZxObjects.LoanOrder memory loanOrder, 
        BZxObjects.LoanPosition memory loanPosition)
    internal
    view
    returns (bool) {
        return shouldLiquidate(
            0x0,
            0x0,
            loanOrder.loanTokenAddress,
            loanPosition.positionTokenAddressFilled,
            loanPosition.collateralTokenAddressFilled,
            loanPosition.loanTokenAmountFilled,
            loanPosition.positionTokenAmountFilled,
            loanPosition.collateralTokenAmountFilled,
            loanOrder.maintenanceMarginAmount);
    }    
}
