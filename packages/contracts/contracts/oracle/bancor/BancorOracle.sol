/**
 * Copyright 2017–2019, bZeroX, LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0.
 */

pragma solidity 0.5.2;

pragma experimental ABIEncoderV2;

import "../../bancor-contracts/token/interfaces/IERC20Token.sol";
import "../../bancor-contracts/converter/interfaces/IBancorConverter.sol";

import "../../openzeppelin-solidity/Math.sol";
import "../../openzeppelin-solidity/SafeMath.sol";

import "../../BZx.sol";
import "../OracleInterface.sol";
import "../../modifiers/EMACollector.sol";
import "../../modifiers/GasRefunder.sol";
import "../../modifiers/BZxOwnable.sol";
import "../../storage/BZxObjects.sol";
import "../../tokens/EIP20.sol";
import "../../shared/WETHInterface.sol";

contract BancorOracle is BZxOwnable, OracleInterface, EMACollector, GasRefunder {
    using SafeMath for uint256;    

    // version
    string public constant version = "0.0.1";

    uint256 public constant RATE_MULTIPLIER = 10**18;

    // Bounty hunters are remembursed from collateral
    // The oracle requires a minimum amount
    uint256 public minimumCollateralInWethAmount = 0.5 ether;

    // If true, the collateral must not be below minimumCollateralInWethAmount for the loan to be opened
    // If false, the loan can be opened, but it won't be insured by the insurance fund if collateral is below minimumCollateralInWethAmount
    bool public enforceMinimum = false;

    // Percentage of interest retained as fee
    // This will always be between 0 and 100
    uint256 public interestFeePercent = 10;

    // Percentage of EMA-based gas refund paid to bounty hunters after successfully liquidating a position
    uint256 public bountyRewardPercent = 110;

    // An upper bound estimation on the liquidation gas cost
    uint256 public gasUpperBound = 600000;

    // bZx vault address    
    address public vault;

    // WETH token address
    address public weth;

    // Bancor converter
    IBancorConverter public bancorConverter;

    /// @notice Constructor
    constructor(
        address _vault,                
        address _bZxContractAddress,
        address _bancorConverter,
        address _weth)
    public {
        require(_vault != address(0x0), "BancorOracle::constructor: Invalid vault address");
        require(_bZxContractAddress != address(0x0), "BancorOracle::constructor: Invalid bZx address");
        require(_bancorConverter != address(0x0), "BancorOracle::constructor: Invalid Bancor converter address");
        require(_weth != address(0x0), "BancorOracle::constructor: Invalid WETH address");

        vault = _vault;
        bZxContractAddress = _bZxContractAddress;
        bancorConverter = IBancorConverter(_bancorConverter);
        weth = _weth;

        // settings for EMACollector
        emaValue = 8 * 10**9 wei; // set an initial price average for gas (8 gwei)
        emaPeriods = 10; // set periods to use for EMA calculation
    }

    function didAddOrder(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanOrderAux memory,
        bytes memory oracleData,
        address,
        uint256)
    public 
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {        
        return true;
    }

    function didTakeOrder(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanOrderAux memory, 
        BZxObjects.LoanPosition memory loanPosition, 
        address, 
        uint256)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didTradePosition(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanPosition memory, 
        uint256)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didPayInterest(
        BZxObjects.LoanOrder memory loanOrder, 
        address lender, 
        uint256 amountOwed, 
        bool, 
        uint256)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        // InterestFeePercent is only editable by owner
        uint256 interestFee = amountOwed.mul(interestFeePercent).div(100);

        // Transfers the interest to the lender, less the interest fee.
        // The fee is retained by the oracle.
        return EIP20(loanOrder.interestTokenAddress).transfer(lender, amountOwed.sub(interestFee));
    }

    function didDepositCollateral(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanPosition memory, 
        uint256,
        uint256)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didWithdrawCollateral(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanPosition memory, 
        uint256,
        uint256)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didChangeCollateral(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanPosition memory, 
        uint256)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didWithdrawPosition(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanPosition memory, 
        uint256, 
        uint256)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didDepositPosition(
        BZxObjects.LoanOrder memory,
        BZxObjects.LoanPosition memory,
        uint256,
        uint256)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didCloseLoanPartially(
        BZxObjects.LoanOrder memory /* loanOrder */,
        BZxObjects.LoanPosition memory /* loanPosition */,
        address payable/* loanCloser */,
        uint256 /* closeAmount */,
        uint256 /* gasUsed */)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didCloseLoan(
        BZxObjects.LoanOrder memory /* loanOrder */,
        BZxObjects.LoanPosition memory /* loanPosition */,
        address payable loanCloser,
        bool isLiquidation,
        uint256 gasUsed)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        // sends gas and bounty reward to bounty hunter
        
        
        if (isLiquidation) {
            (uint256 refundAmount, uint256 finalGasUsed) = getGasRefund(
                gasUsed,
                emaValue,
                bountyRewardPercent
            );

            if (refundAmount > 0) {
                // refunds are paid in ETH
                uint256 wethBalance = EIP20(weth).balanceOf.gas(4999)(address(this));
                if (refundAmount > wethBalance)
                    refundAmount = wethBalance;

                WETHInterface(weth).withdraw(refundAmount);

                sendGasRefund(
                    loanCloser,
                    refundAmount,
                    finalGasUsed,
                    emaValue
                );
            }
        }

        return true;
    }
    
    function didChangeTraderOwnership(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanPosition memory, 
        address, 
        uint256)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didChangeLenderOwnership(
        BZxObjects.LoanOrder memory, 
        address, 
        address, 
        uint256)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didIncreaseLoanableAmount(
        BZxObjects.LoanOrder memory, 
        address, 
        uint256, 
        uint256, 
        uint256)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function trade(
        address _src, 
        address _dest, 
        uint256 _srcAmount,
        uint256 _destAmount)
    public
    onlyBZx
    returns (uint256 destToken, uint256 srcAmount) {
        require(EIP20(_src).balanceOf(address(this)) >= _srcAmount, "BancorOracle::trade: Src token balance is not enough");        
        require(EIP20(_src).approve(address(bancorConverter), _srcAmount), "BancorOracle::trade: Unable to set allowance");
        
        destToken = bancorConverter.convert(IERC20Token(_src), IERC20Token(_dest), _srcAmount, 1);
        
        return (destToken, _srcAmount);
    }

    function tradePosition(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition,
        address destTokenAddress,
        uint256 maxDestTokenAmount,
        bool ensureHealthy)
    public
    onlyBZx
    returns (uint256 destTokenAmountReceived, uint256 sourceTokenAmountUsed) {        
        (destTokenAmountReceived, sourceTokenAmountUsed) = trade(
            loanPosition.positionTokenAddressFilled,
            destTokenAddress,
            loanPosition.positionTokenAmountFilled,
            maxDestTokenAmount);

        if (ensureHealthy) {
            loanPosition.positionTokenAddressFilled = destTokenAddress;
            loanPosition.positionTokenAmountFilled = destTokenAmountReceived;

            // trade can't trigger liquidation
            if (shouldLiquidate(
                loanOrder,
                loanPosition)) {
                revert("BancorOracle::tradePosition: trade triggers liquidation");
            }
        }        
    }

    function verifyAndLiquidate(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition)
    public
    onlyBZx
    returns (uint256 destTokenAmount, uint256 sourceTokenAmountUsed) {
        if (!shouldLiquidate(loanOrder, loanPosition)) {
            return (0,0);
        }

        return trade(
            loanPosition.positionTokenAddressFilled,
            loanOrder.loanTokenAddress,
            loanPosition.positionTokenAmountFilled,
            0);
    }

    // note: bZx will only call this function if isLiquidation=true or loanTokenAmountNeeded > 0
    function processCollateral(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition,
        uint256 loanTokenAmountNeeded,
        bool isLiquidation) 
    public
    onlyBZx
    returns (uint256 loanTokenAmountCovered, uint256 collateralTokenAmountUsed) {
        // require(isLiquidation || loanTokenAmountNeeded > 0, "!isLiquidation && loanTokenAmountNeeded == 0");

        // uint256 collateralTokenBalance = EIP20(loanPosition.collateralTokenAddressFilled).balanceOf.gas(4999)(address(this)); // Changes to state require at least 5000 gas
        // if (collateralTokenBalance < loanPosition.collateralTokenAmountFilled) { // sanity check
        //     revert("BZxOracle::processCollateral: collateralTokenBalance < loanPosition.collateralTokenAmountFilled");
        // }
         
        revert("Not implemented yet"); // TODO
    }

    /*
    * Public View functions
    */

    function shouldLiquidate(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition)
    public
    view
    returns (bool) {
        return false;
        return (
            getCurrentMarginAmount(
                loanOrder.loanTokenAddress,
                loanPosition.positionTokenAddressFilled,
                loanPosition.collateralTokenAddressFilled,
                loanPosition.loanTokenAmountFilled,
                loanPosition.positionTokenAmountFilled,
                loanPosition.collateralTokenAmountFilled) <= loanOrder.maintenanceMarginAmount
            );
    }

    function isTradeSupported(
        address src, 
        address dest, 
        uint256 srcAmount)
    public
    view
    returns (bool) {      
        (uint256 rate, uint256 destAmount) = getTradeData(src, dest, srcAmount);
        return destAmount > 0 && rate > 0;
    }

    function getTradeData(
        address src, 
        address dest, 
        uint256 srcAmount)
    public
    view
    returns (uint256 rate, uint256 destAmount) {
        (rate,) = getExpectedRate(src, dest, srcAmount);        
        destAmount = srcAmount.mul(rate).div(RATE_MULTIPLIER);
    }

    // returns bool isPositive, uint256 offsetAmount
    // the position's offset from loan principal denominated in positionToken
    function getPositionOffset(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition)
    public
    view
    returns (bool isPositive, uint256 positionOffsetAmount, uint256 loanOffsetAmount) {    
            
        uint256 collateralToPositionAmount;
        if (loanPosition.collateralTokenAddressFilled == loanPosition.positionTokenAddressFilled) {
            collateralToPositionAmount = loanPosition.collateralTokenAmountFilled;
        } else {
            (uint256 collateralToPositionRate,) = getExpectedRate(
                loanPosition.collateralTokenAddressFilled,
                loanPosition.positionTokenAddressFilled,
                loanPosition.collateralTokenAmountFilled);
            if (collateralToPositionRate == 0) {
                return (false,0,0);
            }
            collateralToPositionAmount = loanPosition.collateralTokenAmountFilled.mul(collateralToPositionRate).div(RATE_MULTIPLIER);
        }

        uint256 loanToPositionAmount;
        uint256 loanToPositionRate;
        if (loanOrder.loanTokenAddress == loanPosition.positionTokenAddressFilled) {
            loanToPositionAmount = loanPosition.loanTokenAmountFilled;
            loanToPositionRate = 10**18;
        } else {
            (loanToPositionRate,) = getExpectedRate(
                loanOrder.loanTokenAddress,
                loanPosition.positionTokenAddressFilled,
                loanPosition.loanTokenAmountFilled);

            if (loanToPositionRate == 0) {
                return (false,0,0);
            }

            loanToPositionAmount = loanPosition.loanTokenAmountFilled.mul(loanToPositionRate).div(RATE_MULTIPLIER);
        }

        uint256 combinedCollateral = loanPosition.positionTokenAmountFilled.add(collateralToPositionAmount);
        uint256 initialCombinedCollateral = loanToPositionAmount.add(loanToPositionAmount.mul(loanOrder.initialMarginAmount).div(10**20));

        isPositive = false;
        uint256 netCollateral = 0;
        if (combinedCollateral > initialCombinedCollateral) {
            netCollateral = combinedCollateral.sub(initialCombinedCollateral);
            isPositive = true;
        } else if (combinedCollateral < initialCombinedCollateral) {
            netCollateral = initialCombinedCollateral.sub(combinedCollateral);
        }

        positionOffsetAmount = Math.min256(loanPosition.positionTokenAmountFilled, netCollateral);

        loanOffsetAmount = netCollateral.mul(RATE_MULTIPLIER).div(loanToPositionRate);
    }

    /// @return The current margin amount (a percentage -> i.e. 54350000000000000000 == 54.35%)
    function getCurrentMarginAmount(
        address loanTokenAddress,
        address positionTokenAddress,
        address collateralTokenAddress,
        uint256 loanTokenAmount,
        uint256 positionTokenAmount,
        uint256 collateralTokenAmount)
    public
    view
    returns (uint256) {
        uint256 estimatedLoanValue;

        if (collateralTokenAddress == loanTokenAddress) {
            estimatedLoanValue = collateralTokenAmount;
        } else {
            (uint256 collateralToLoanRate,) = getExpectedRate(collateralTokenAddress, loanTokenAddress, collateralTokenAmount);

            if (collateralToLoanRate == 0) {
                return 0; // Unsupported trade
            }

            estimatedLoanValue = collateralTokenAmount.mul(collateralToLoanRate).div(RATE_MULTIPLIER);
        }

        uint256 estimatedPositionValue;
        if (positionTokenAddress == loanTokenAddress) {
            estimatedPositionValue = positionTokenAmount;
        } else {
            (uint256 positionToLoanRate,) = getExpectedRate(positionTokenAddress, loanTokenAddress, positionTokenAmount);
            if (positionToLoanRate == 0) {
                return 0; // Unsupported trade
            }
            estimatedPositionValue= positionTokenAmount.mul(positionToLoanRate).div(RATE_MULTIPLIER);
        }

        uint256 totalCollateral = estimatedLoanValue.add(estimatedPositionValue);
        if (totalCollateral > loanTokenAmount) {
            return totalCollateral.sub(loanTokenAmount).mul(10**20).div(loanTokenAmount);
        }

        return 0;        
    }

    /*
    * Owner functions
    */

    function setMinimumCollateralInWethAmount(uint256 newValue, bool enforce)
    public
    onlyOwner {
        if (newValue != minimumCollateralInWethAmount) {
            minimumCollateralInWethAmount = newValue;
        }   

        if (enforce != enforceMinimum) {
            enforceMinimum = enforce;
        }            
    }

    function setInterestFeePercent(uint256 newRate)
    public
    onlyOwner {
        require(newRate != interestFeePercent && newRate <= 100);
        interestFeePercent = newRate;
    }

    function setBountyRewardPercent(uint256 newValue)
    public
    onlyOwner {
        require(newValue != bountyRewardPercent);
        bountyRewardPercent = newValue;
    }

    function setGasUpperBound(uint256 newValue)
    public
    onlyOwner {
        require(newValue != gasUpperBound);
        gasUpperBound = newValue;
    }

    function setVaultAddress(address newAddress)
    public
    onlyOwner {
        require(newAddress != vault && newAddress != address(0));
        vault = newAddress;
    }

    function setEMAValue(uint256 _newEMAValue)
    public
    onlyOwner {
        require(_newEMAValue != emaValue);
        emaValue = _newEMAValue;
    }

    function setEMAPeriods(uint256 _newEMAPeriods)
    public
    onlyOwner {
        require(_newEMAPeriods > 1 && _newEMAPeriods != emaPeriods);
        emaPeriods = _newEMAPeriods;
    }

    function transferEther(address payable to, uint256 value)
    public
    onlyOwner
    returns (bool) {
        return to.send(value);
    }

    function transferToken(address tokenAddress, address to, uint256 value)
    public
    onlyOwner
    returns (bool) {
        return EIP20(tokenAddress).transfer(to, value);
    }

    /// @dev expected rate = (dest / src) * 10^18
    function getExpectedRate(address src, address dest, uint256 srcAmount)
    public
    view
    returns (uint256 expectedRate, uint256 slippageRate) {
        // returns expected conversion return amount and conversion fee
        (uint256 destAmount, uint256 fee) = bancorConverter.getReturn(IERC20Token(src), IERC20Token(dest), srcAmount);

        uint256 rate = destAmount.mul(RATE_MULTIPLIER).div(srcAmount);

        return (rate, rate);
    }    
}