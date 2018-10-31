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

    // version
    string public constant version = "0.0.2";

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

    // Orders depths
    uint public augurLoopLimit = 1;
    uint public DELETE_2 = 0; // TODO: not used

    // bZx vault address    
    address public vault;

    // WETH token address
    address public weth;

    // Augur Network adapter address
    IAugurNetworkAdapter public augurNetwork;

    // allowed markets mapping ([order hash] -> [[maker address] -> [allowed or not]])
    mapping (bytes32 => mapping (address => bool)) public allowedMarkets;  

    /// @notice Constructor
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

    /// @dev TODO: just for test, REMOVE ME!
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
        
        augurLoopLimit = 1;
        gasUpperBound = 600000;
        bountyRewardPercent = 110;
        interestFeePercent = 10;
        enforceMinimum = false;
        minimumCollateralInWethAmount = 0.5 ether;
    }  

   function didAddOrder(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanOrderAux,
        bytes oracleData,
        address,
        uint)
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

    function didTradePosition(
        BZxObjects.LoanOrder memory loanOrder, 
        BZxObjects.LoanPosition memory loanPosition, 
        uint)
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

    function didPayInterest(
        BZxObjects.LoanOrder memory loanOrder, 
        address lender, 
        uint amountOwed, 
        bool, 
        uint)
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

    function didDepositCollateral(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanPosition memory, 
        uint,
        uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didWithdrawCollateral(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanPosition memory, 
        uint,
        uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didChangeCollateral(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanPosition memory, 
        uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didWithdrawProfit(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanPosition memory, 
        uint, 
        uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didDepositPosition(
        BZxObjects.LoanOrder memory,
        BZxObjects.LoanPosition memory,
        uint,
        uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didWithdrawPosition(
        BZxObjects.LoanOrder memory,
        BZxObjects.LoanPosition memory,
        uint,
        uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didCloseLoanPartially(
        BZxObjects.LoanOrder memory /* loanOrder */,
        BZxObjects.LoanPosition memory /* loanPosition */,
        address /* loanCloser */,
        uint /* closeAmount */,
        uint /* gasUsed */)
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
    
    function didChangeTraderOwnership(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanPosition memory, 
        address, 
        uint)
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
        uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function didIncreaseLoanableAmount(
        BZxObjects.LoanOrder memory, 
        address, 
        uint, 
        uint, 
        uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        return true;
    }

    function doManualTrade(
        address src, 
        address dest, 
        uint srcAmount,
        uint maxDestTokenAmount)
    public
    returns (uint, uint) {
        return doTrade(src, dest, srcAmount, maxDestTokenAmount);
    }

    function doTrade(
        address src, 
        address dest, 
        uint srcAmount,
        uint)
    public
    onlyBZx
    returns (uint, uint) {
        // make sure that the oracle have received enough src token to do a trade
        require(EIP20(src).balanceOf(address(this)) >= srcAmount, "AugurOracle::_doTrade: Src token balance is not enough");

        // weth and augur share token are not protected against double spend attack 
        // no need to set allowance to 0
        require(EIP20(src).approve(augurNetwork, srcAmount), "AugurOracle::_doTrade: Unable to set allowance");

        (uint rate, uint worstRate) = augurNetwork.getExpectedRate(src, dest, srcAmount, augurLoopLimit);

        uint result;
        uint destToken;

        // a rate always shows how much weth should be spent to buy 1 share token, i.e rate = weth/share_token
        if (src == weth) {
            (result, destToken) = augurNetwork.trade(src, srcAmount, dest, srcAmount.div(rate), worstRate, vault, augurLoopLimit);
        } else {
            assert(dest == weth);
            (result, destToken) = augurNetwork.trade(src, srcAmount, dest, srcAmount.mul(rate), worstRate, vault, augurLoopLimit);
        }
        
        require(result == augurNetwork.OK(), "AugurOracle::_doTrade: trade failed");

        return (destToken, srcAmount);
    }

    function verifyAndLiquidate(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition)
    public
    onlyBZx
    returns (uint destTokenAmount, uint sourceTokenAmountUsed) {
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
            return (0,0);
        }

        return doTrade(
            loanPosition.positionTokenAddressFilled,
            loanOrder.loanTokenAddress,
            loanPosition.positionTokenAmountFilled,
            0);
    }

    // note: bZx will only call this function if isLiquidation=true or loanTokenAmountNeeded > 0
    function processCollateral(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition,
        uint loanTokenAmountNeeded,
        bool) 
    public
    onlyBZx
    returns (uint loanTokenAmountCovered, uint collateralTokenAmountUsed) {
        require(loanPosition.collateralTokenAddressFilled == weth, 
            "AugurOracle::processCollateral: Invalid state, only weth is accepted as a collateral");
        
        // collateralTokenAddressFilled == weth
        uint collateralTokenBalance = EIP20(loanPosition.collateralTokenAddressFilled).balanceOf(this);
        require(collateralTokenBalance >= loanPosition.collateralTokenAmountFilled,
            "AugurOracle::processCollateral: collateralTokenBalance < loanPosition.collateralTokenAmountFilled");
   
        if (loanTokenAmountNeeded > 0) {
            // collateral is always weth, just send everything back
            if (loanOrder.loanTokenAddress == weth) {
                require(collateralTokenBalance >= loanTokenAmountNeeded, 
                    "AugurOracle::processCollateral: Has no enough collateral");

                require(EIP20(loanOrder.loanTokenAddress).transfer(vault, loanPosition.collateralTokenAmountFilled), 
                    "AugurOracle::processCollateral: Unable to sent collateral back");

                return (loanTokenAmountNeeded, loanTokenAmountNeeded);
            } else {                
                (uint rate, uint slippage, uint loop) = augurNetwork.estimateRate(
                    loanPosition.collateralTokenAddressFilled, 
                    loanOrder.loanTokenAddress,
                    loanTokenAmountNeeded);
                
                collateralTokenAmountUsed = loanTokenAmountNeeded.mul(rate);
                
                require(EIP20(loanPosition.collateralTokenAddressFilled).approve(augurNetwork, collateralTokenAmountUsed), 
                    "AugurOracle::_doTrade: Unable to set allowance");

                (, loanTokenAmountCovered) = augurNetwork.trade(
                    loanPosition.collateralTokenAddressFilled, 
                    collateralTokenAmountUsed, 
                    loanOrder.loanTokenAddress, 
                    loanTokenAmountNeeded, 
                    slippage, 
                    vault, 
                    loop);

                require(EIP20(loanPosition.collateralTokenAddressFilled).transfer(vault, loanPosition.collateralTokenAmountFilled - collateralTokenAmountUsed), 
                    "AugurOracle::processCollateral: Unable to sent collateral back");

                return (loanTokenAmountCovered, collateralTokenAmountUsed);
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
        (uint rate, uint worstRate) = augurNetwork.getExpectedRate(src, dest, srcAmount, augurLoopLimit);  
        return rate > 0 || worstRate > 0;
    }

    function getTradeData(address src, address dest, uint srcAmount)
    public
    view
    returns (uint rate, uint destAmount) {
        (rate,) = getExpectedRate(src, dest, srcAmount);        
        destAmount = srcAmount.mul(rate).div(10**18);
    }

    // returns bool isProfit, uint profitOrLoss
    // the position's profit/loss denominated in positionToken
    function getProfitOrLoss(
        address positionToken,
        address loanToken,
        uint positionAmount,
        uint loanAmount)
    public
    view
    returns (bool, uint) {
        (, uint slippage) = getExpectedRate(loanToken, positionToken, loanAmount);

        uint estimatedPositionAmount = isWETHToken(positionToken) 
            ? loanAmount.div(slippage)
            : loanAmount.mul(slippage);

        if (positionAmount > estimatedPositionAmount) {
            return (true, positionAmount - estimatedPositionAmount);
        } else {
            return (false, estimatedPositionAmount - positionAmount);
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
        uint estimatedLoanValue;

        if (collateralTokenAddress == loanTokenAddress) {
            estimatedLoanValue = collateralTokenAmount;
        } else {
            (uint collateralToLoanRate,) = getExpectedRate(collateralTokenAddress, loanTokenAddress, collateralTokenAmount);

            if (collateralToLoanRate == 0) {
                return 0; // Unsupported trade
            }

            estimatedLoanValue = collateralTokenAmount.mul(collateralToLoanRate).div(10**18);
        }

        uint estimatedPositionValue;
        if (positionTokenAddress == loanTokenAddress) {
            estimatedPositionValue = positionTokenAmount;
        } else {
            (uint positionToLoanRate,) = getExpectedRate(positionTokenAddress, loanTokenAddress, positionTokenAmount);
            if (positionToLoanRate == 0) {
                return 0; // Unsupported trade
            }
            estimatedPositionValue= positionTokenAmount.mul(positionToLoanRate).div(10**18);
        }

        return estimatedLoanValue.add(estimatedPositionValue).sub(loanTokenAmount).mul(10**20).div(loanTokenAmount);
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
    
    /// @dev expected rate = (dest / src) * 10^18
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
        
        (uint rate, uint slippage) = augurNetwork.getExpectedRate(src, dest, srcAmount, augurLoopLimit);  

        if (src == weth) {
            return (RATE_COEFF.div(rate), RATE_COEFF.div(slippage));            
        } else if (dest == weth) {
            return (rate.mul(RATE_COEFF), slippage.mul(RATE_COEFF));
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
