/**
 * Copyright 2017–2018, bZeroX, LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0.
 */

pragma solidity 0.5.2;

pragma experimental ABIEncoderV2;

import "../../openzeppelin-solidity/Math.sol";
import "../../openzeppelin-solidity/SafeMath.sol";

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
    string public constant version = "0.0.3";

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
    uint public augurLoopLimit = 3;
    uint public DELETE_2 = 0; // TODO: not used

    // bZx vault address    
    address public vault;

    // WETH token address
    address public weth;

    // Augur Network adapter address
    IAugurNetworkAdapter public augurNetwork;

    uint public constant RATE_MULTIPLIER = 10**18;

    // allowed markets mapping ([order hash] -> [[market address] -> [allowed or not]])
    mapping (bytes32 => mapping (address => bool)) public allowedMarkets;

    // allowed markets mapping ([order hash] -> [array of allowed markets])
    mapping (bytes32 => address[]) public allowedMarketsList;

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
        
        augurLoopLimit = 3;
        gasUpperBound = 600000;
        bountyRewardPercent = 110;
        interestFeePercent = 10;
        enforceMinimum = false;
        minimumCollateralInWethAmount = 0.5 ether;
    }  

    function didAddOrder(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanOrderAux memory,
        bytes memory oracleData,
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
        allowedMarketsList[loanOrderHash] = markets;
        
        return true;
    }

    function didTakeOrder(
        BZxObjects.LoanOrder memory, 
        BZxObjects.LoanOrderAux memory, 
        BZxObjects.LoanPosition memory loanPosition, 
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
        BZxObjects.LoanOrder memory /* loanOrder */, 
        BZxObjects.LoanPosition memory /* loanPosition */, 
        uint)
    public
    onlyBZx
    updatesEMA(tx.gasprice)
    returns (bool) {
        // // make sure that a trade is permitted by maker
        // address positionToken = loanPosition.positionTokenAddressFilled;
        // address loadToken = loanOrder.loanTokenAddress;

        // if (augurNetwork.isShareToken(positionToken)) {
        //     if (!isMarketAllowed(loanOrder.loanOrderHash, IShareToken(positionToken).getMarket())) {
        //         return false;
        //     }
        // }

        // if (augurNetwork.isShareToken(loadToken)) {        
        //     if (!isMarketAllowed(loanOrder.loanOrderHash, IShareToken(loadToken).getMarket())) {
        //         return false;
        //     }
        // }        

        // // make sure that an order is still valid
        // if (shouldLiquidate(loanOrder, loanPosition)) {
        //     return false;
        // }

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
        return false;
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

    function didCloseLoanPartially(
        BZxObjects.LoanOrder memory /* loanOrder */,
        BZxObjects.LoanPosition memory /* loanPosition */,
        address payable/* loanCloser */,
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
        address payable loanCloser,
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
                uint wethBalance = EIP20(weth).balanceOf.gas(4999)(address(this));
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

    function trade(
        address _src, 
        address _dest, 
        uint _srcAmount,
        uint)
    public
    onlyBZx
    returns (uint destToken, uint srcAmount) {
        // make sure that the oracle have received enough src token to do a trade
        require(EIP20(_src).balanceOf(address(this)) >= _srcAmount, "AugurOracle::_doTrade: Src token balance is not enough");

        // weth and augur share token are not protected against double spend attack 
        // no need to set allowance to 0
        require(EIP20(_src).approve(address(augurNetwork), _srcAmount), "AugurOracle::_doTrade: Unable to set allowance");

        (uint rate, uint worstRate) = augurNetwork.getSwapRate(_src, _srcAmount, _dest, augurLoopLimit);
        
        return tradeWithAugur(_src, _srcAmount, _dest, _srcAmount.mul(rate).div(RATE_MULTIPLIER), worstRate);
    }

    function tradeWithAugur(
        address _src,         
        uint _srcAmount,
        address _dest, 
        uint _destAmount,
        uint _rate)
    internal
    returns (uint destToken, uint srcAmount) {
        uint result;
        (result, srcAmount, destToken) = augurNetwork.trade(_src, _srcAmount, _dest, _destAmount, _rate, vault, augurLoopLimit);
                
        require(result == augurNetwork.OK(), "AugurOracle::_doTrade: trade failed");        
    }

    function tradePosition(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition,
        address destTokenAddress,
        uint maxDestTokenAmount,
        bool ensureHealthy)
    public
    onlyBZx
    returns (uint destTokenAmountReceived, uint sourceTokenAmountUsed) {
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
                revert("AugurOracle::tradePosition: trade triggers liquidation");
            }
        }        
    }

    function verifyAndLiquidate(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition)
    public
    onlyBZx
    returns (uint destTokenAmount, uint sourceTokenAmountUsed) {
        if (!shouldLiquidate(
            loanOrder,
            loanPosition)) {
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
        uint loanTokenAmountNeeded,
        bool) 
    public
    onlyBZx
    returns (uint loanTokenAmountCovered, uint collateralTokenAmountUsed) {
        require(loanPosition.collateralTokenAddressFilled == weth, 
            "AugurOracle::processCollateral: Invalid state, only weth is accepted as a collateral");
        
        // collateralTokenAddressFilled == weth
        uint collateralTokenBalance = EIP20(loanPosition.collateralTokenAddressFilled).balanceOf(address(this));
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
                (uint rate, uint slippage) = augurNetwork.getSwapRate(
                    loanPosition.collateralTokenAddressFilled, 
                    loanTokenAmountNeeded,
                    loanOrder.loanTokenAddress,
                    augurLoopLimit);
                
                collateralTokenAmountUsed = loanTokenAmountNeeded.mul(rate).div(RATE_MULTIPLIER);
                
                require(EIP20(loanPosition.collateralTokenAddressFilled).approve(address(augurNetwork), collateralTokenAmountUsed), 
                    "AugurOracle::_doTrade: Unable to set allowance");

                (, collateralTokenAmountUsed, loanTokenAmountCovered) = augurNetwork.trade(
                    loanPosition.collateralTokenAddressFilled, 
                    collateralTokenAmountUsed, 
                    loanOrder.loanTokenAddress, 
                    loanTokenAmountNeeded, 
                    slippage, 
                    vault, 
                    augurLoopLimit);

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
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition)
        public
        view
        returns (bool) {
        return false; // TODO

        return (
            getCurrentMarginAmount(
                loanOrder.loanTokenAddress,
                loanPosition.positionTokenAddressFilled,
                loanPosition.collateralTokenAddressFilled,
                loanPosition.loanTokenAmountFilled,
                loanPosition.positionTokenAmountFilled,
                loanPosition.collateralTokenAmountFilled) <= loanOrder.maintenanceMarginAmount.mul(10**18)
            );
    }

    function isTradeSupported(
        address src, 
        address dest, 
        uint srcAmount)
    public
    view
    returns (bool) {      
        (uint rate, uint worstRate) = augurNetwork.getSwapRate(src, srcAmount, dest, augurLoopLimit);  
        return rate > 0 || worstRate > 0;
    }

    function getTradeData(
        address src, 
        address dest, 
        uint srcAmount)
    public
    view
    returns (uint rate, uint destAmount) {
        (rate,) = getExpectedRate(src, dest, srcAmount);        
        destAmount = srcAmount.mul(rate).div(RATE_MULTIPLIER);
    }

    // returns bool isPositive, uint offsetAmount
    // the position's offset from loan principal denominated in positionToken
    function getPositionOffset(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition)        
    public
    view
    returns (bool isPositive, uint offsetAmount) {
        bool isPositionInWETH = isWETHToken(loanPosition.positionTokenAddressFilled);
        
        uint collateralToPositionAmount;
        if (loanPosition.collateralTokenAddressFilled == loanPosition.positionTokenAddressFilled) {
            collateralToPositionAmount = loanPosition.collateralTokenAmountFilled;
        } else {
            (, uint collateralSlippage) = getExpectedRate(loanPosition.collateralTokenAddressFilled, loanPosition.positionTokenAddressFilled, loanPosition.collateralTokenAmountFilled);
            collateralToPositionAmount = isPositionInWETH
                ? loanPosition.collateralTokenAmountFilled.mul(RATE_MULTIPLIER).div(collateralSlippage)
                : loanPosition.collateralTokenAmountFilled.mul(collateralSlippage).div(RATE_MULTIPLIER);
        }

        uint loanToPositionAmount;
        if (loanOrder.loanTokenAddress == loanPosition.positionTokenAddressFilled) {
            loanToPositionAmount = loanPosition.loanTokenAmountFilled;
        } else {
            (, uint loanSlippage) = getExpectedRate(loanOrder.loanTokenAddress, loanPosition.positionTokenAddressFilled, loanPosition.loanTokenAmountFilled);
            loanToPositionAmount = isPositionInWETH
                ? loanPosition.loanTokenAmountFilled.mul(RATE_MULTIPLIER).div(loanSlippage)
                : loanPosition.loanTokenAmountFilled.mul(loanSlippage).div(RATE_MULTIPLIER);
        }

        uint initialPosition = loanToPositionAmount.add(loanToPositionAmount.mul(loanOrder.initialMarginAmount).div(100));
        uint currentPosition = loanPosition.positionTokenAmountFilled.add(collateralToPositionAmount);
        if (currentPosition > initialPosition) {
            isPositive = true;
            offsetAmount = Math.min256(loanPosition.positionTokenAmountFilled, currentPosition - initialPosition);
        } else {
            isPositive = false;
            offsetAmount = initialPosition - currentPosition;
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

            estimatedLoanValue = collateralTokenAmount.mul(collateralToLoanRate).div(RATE_MULTIPLIER);
        }

        uint estimatedPositionValue;
        if (positionTokenAddress == loanTokenAddress) {
            estimatedPositionValue = positionTokenAmount;
        } else {
            (uint positionToLoanRate,) = getExpectedRate(positionTokenAddress, loanTokenAddress, positionTokenAmount);
            if (positionToLoanRate == 0) {
                return 0; // Unsupported trade
            }
            estimatedPositionValue= positionTokenAmount.mul(positionToLoanRate).div(RATE_MULTIPLIER);
        }

        uint totalCollateral = estimatedLoanValue.add(estimatedPositionValue);
        if (totalCollateral > loanTokenAmount) {
            return totalCollateral.sub(loanTokenAmount).mul(10**20).div(loanTokenAmount);
        }

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

    function transferEther(address payable to, uint value)
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

    function getShareVolume(
        address _shareToken, 
        Order.Types _orderType)
    public
    view
    returns (uint) {
        return augurNetwork.getVolume(_shareToken, _orderType, augurLoopLimit);
    }

    function getShareTokens(address _market)
    public
    view
    returns (address[] memory) {
        return augurNetwork.getShareTokens(_market);
    }

    function getSharesData(address _market) 
    public
    view
    returns (address[] memory shares, uint[] memory volumes, Order.Types[] memory types) {
        address[] memory tokens = getShareTokens(_market);
        uint size = tokens.length;

        shares = new address[](size * 2);
        volumes = new uint[](size * 2);
        types = new Order.Types[](size * 2);

        for(uint i = 0; i < size; i++) {
            address token = tokens[i];

            shares[i] = token;
            volumes[i] = getShareVolume(token, Order.Types.Ask);
            types[i] = Order.Types.Ask;

            shares[i + size] = token;
            volumes[i + size] = getShareVolume(token, Order.Types.Bid);
            types[i + size] = Order.Types.Bid;
        }
    }

    function isMarketAllowed(bytes32 _orderhash, address _market) 
    public
    view
    returns (bool) {
        return allowedMarkets[_orderhash][_market];
    }

    function setAllowedMarkets(bytes32 _orderHash, address[] memory _markets)
    public
    returns (bool) {
        require(_orderHash != bytes32(0x0), "AugurOracle::allowMarketTrading: Invalid order hash");
        require(_markets.length > 0, "AugurOracle::allowMarketTrading: Markets list is empty");

        BZxObjects.LoanOrderAux memory orderAux = BZx(bZxContractAddress).getLoanOrderAux(_orderHash);

        // TODO: ahiatsevich: should trader be permitted to change markets?        
        if (orderAux.makerAddress != msg.sender) {
            revert("orderAux.maker != msg.sender");
        }

        for (uint i = 0; i < _markets.length; i++) {
            allowedMarkets[_orderHash][_markets[i]] = true;
        }
        allowedMarketsList[_orderHash] = _markets;

        return true;
    }
    
    /// @dev expected rate = (dest / src) * 10^18
    function getExpectedRate(address src, address dest, uint srcAmount)
    public
    view
    returns (uint expectedRate, uint slippageRate) {
        if (src != weth && dest != weth) {
            return (0, 0);
        }
        
        if (src == dest) {
            return ((10**18), (10**18));
        }
        
        return augurNetwork.getSwapRate(src, srcAmount, dest, augurLoopLimit);  
    }

    function isWETHToken(address _token)
    public 
    view
    returns (bool) {
        return _token == weth;
    }

    function parseAddresses(bytes memory data)
    public
    pure
    returns (address[] memory result) {
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
