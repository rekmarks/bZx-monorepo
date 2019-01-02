pragma solidity 0.5.2;

import "../../openzeppelin-solidity/SafeMath.sol";
import "./IAugurNetworkAdapter.sol";


/// @title AugurAdapter contract
contract AugurNetworkAdapter is IAugurNetworkAdapter {
    using SafeMath for uint256;

    IController public augurController;
    IWETH public weth;

    /// @dev Make sure that ETH is not stuck in OracleAdapter after function invocation 
    modifier ensureBalanceUnchanged() {
        uint initialBalance = address(this).balance;
        _;
        require(initialBalance == address(this).balance, "AugurAdapter::ensureBalanceUnchanged: Balance is changed");
    }
    
    /// @dev Make sure that given token is not stuck in OracleAdapter after function invocation 
    modifier ensureTokenBalanceUnchanged(ERC20 token) {
        uint initialBalance = token.balanceOf(address(this));
        _;
        require(initialBalance == token.balanceOf(address(this)), "AugurAdapter::ensureTokenBalanceUnchanged: Token balance is changed");
    }

    /// @notice Conctructor
    /// @dev Eternal approval of `Cash` token is performed. 
    /// `Augur` will be permitted to withdraw from the contract unlimited amount of Cash.
    /// @param _augurController is Augur's controller
    /// @param _cash is Cash address
    /// @param _weth is WETH address
    constructor(address _augurController, address _cash, address _weth)
    public {
        require(_augurController != address(0x0), "Invalid Augur controller address");        
        require(_weth != address(0x0), "Invalid WETH address");
        
        augurController = IController(_augurController);
        weth = IWETH(_weth);        

        require(ERC20(_cash).approve(augurController.getAugur(), MAX_UINT), "Failed to set unlimited allowance");
    }

    /// @dev Fallback function. The contract should be able to receive ETH from `Augur`    
    function ()
    external
    payable {
    }

    /// @notice Trade tokens
    function trade(
        address _src, 
        uint _srcAmount, 
        address _dest, 
        uint _maxDestAmount, 
        uint _price,
        address _receiver,
        uint _loopLimit)             
    public
    ensureBalanceUnchanged()
    ensureTokenBalanceUnchanged(ERC20(_src))
    ensureTokenBalanceUnchanged(ERC20(_dest))
    returns (uint, uint, uint) {        
        if(isWETHToken(_src) && isShareToken(_dest)) {
            return buyShares(_srcAmount, IShareToken(_dest), _maxDestAmount, RATE_MULTIPLIER.div(_price), _receiver, msg.sender, _loopLimit);
        } else if (isShareToken(_src) && isWETHToken(_dest)) {
            return sellShares(IShareToken(_src), _srcAmount, _price.div(RATE_MULTIPLIER), _receiver, msg.sender, _loopLimit);
        } else if (isShareToken(_src) && isShareToken(_dest)) {
            return swapShares(IShareToken(_src), _srcAmount, IShareToken(_dest), _maxDestAmount, _price, _receiver, _loopLimit);
        }
        
        return (ERR_BZX_AUGUR_UNSUPPORTED_TOKEN, 0, 0);                      
    }
    
    function getBuyRate(
        address _share,  
        uint _shareAmount,
        uint _loopLimit)         
    public
    view
    returns (uint expectedRate, uint slippageRate) {  
        require(isShareToken(_share), "AugurAdapter::getBuyRate: Invalid Share token");

        return calculateRate(address(weth), MAX_UINT, _share, _shareAmount, _loopLimit);
    }

    function getSellRate(
        address _share,  
        uint _shareAmount,
        uint _loopLimit)         
    public
    view
    returns (uint expectedRate, uint slippageRate) {  
        require(isShareToken(_share), "AugurAdapter::getSellRate: Invalid Share token");

        return calculateRate(_share, _shareAmount, address(weth), MAX_UINT, _loopLimit);
    }

    function getSwapRate(
        address _shareSrc,  
        uint _shareSrcAmount,
        address _shareDest,  
        uint _loopLimit)         
    public
    view
    returns (uint expectedRate, uint slippageRate) { 
        if (isWETHToken(_shareSrc) || isWETHToken(_shareDest)) {
            return calculateRate(_shareSrc, _shareSrcAmount, _shareDest, MAX_UINT, _loopLimit);
        } 

        (uint sellRate, uint slippageSellRate) = 
            calculateRate(_shareSrc, _shareSrcAmount, address(weth), MAX_UINT, _loopLimit);
        (uint buyRate, uint slippageBuyRate) = 
            calculateRate(address(weth), _shareSrcAmount.mul(sellRate).div(RATE_MULTIPLIER), _shareDest, MAX_UINT, _loopLimit);

        return (sellRate.mul(buyRate).div(RATE_MULTIPLIER), slippageSellRate.mul(slippageBuyRate).div(RATE_MULTIPLIER));
    }

    function getVolume(
        address _shareToken, 
        Order.Types _orderType,
        uint _loopLimit)         
    public
    view
    returns (uint) {  
        IOrders ordersService = getOrdersService();

        IShareToken shares = IShareToken(_shareToken);
            
        bytes32 bestOrderID = ordersService.getBestOrderId(_orderType, shares.getMarket(), shares.getOutcome());
        if (bestOrderID == bytes32(0x0)) {
            return 0;
        }
        
        uint shareAmount;
        uint loop;
        do {                              
            shareAmount += ordersService.getAmount(bestOrderID);                
            bestOrderID = ordersService.getWorseOrderId(bestOrderID);            
        } while(bestOrderID != bytes32(0x0) && (++loop) < _loopLimit);
        
        return shareAmount;
    }

    function getShareTokens(
        address _market)         
    public
    view
    returns (address[] memory) {
        uint numberOfOutcomes = IMarket(_market).getNumberOfOutcomes();

        address[] memory shares = new address[](numberOfOutcomes);
        for (uint i = 0; i < numberOfOutcomes; i++) {
            IShareToken token = IMarket(_market).getShareToken(i);
            shares[i] = address(token);
        }

        return shares;
    }

    // /// BUY:  TYPE = 0, WETH -> SHARE
    // /// SELL: TYPE = 1, SHARE -> WETH    
    // function calcTradeDirection(address _src, address _dest)
    // public
    // view
    // returns (Order.TradeDirections) {
    //     if (isWETHToken(_src) && isShareToken(_dest)) {
    //         return Order.TradeDirections.Long;
    //     }
        
    //     assert(isShareToken(_src) && isWETHToken(_dest));
    //     return Order.TradeDirections.Short;
    // }

    function calcOrderType(address _src, address _dest)
    public
    view
    returns (Order.Types) {
        if (isWETHToken(_src) && isShareToken(_dest)) {
            return Order.Types.Ask;
        }
        
        assert(isShareToken(_src) && isWETHToken(_dest));
        return Order.Types.Bid;
    }

    function isWETHToken(address _token) 
    public
    view
    returns (bool) {
        return (_token == address(weth));
    }

    function isShareToken(address _token) 
    public
    view
    returns (bool result) {
        // if (_token == address(0x0)) {
        //     return false;
        // }
        
        // bytes4 sig = 0xdb0a087c; //bytes4(keccak256("getTypeName()"));
        // bytes32 tokenType;
        // assembly {
        //     let data := mload(0x40)
        //     mstore(data, sig) 

        //     let result := call(4999, _token, data, 0x08, data, 0x20)
        //     tokenType := mload(data) 
        // }

        // return tokenType == bytes32("ShareToken");

        // TODO: ahiatsevich: hotfix, just check that the given token is not weth
        return _token!= address(weth);
    }

    function getTradeService()
    public
    view
    returns (ITrade) {
        return ITrade(augurController.lookup("Trade"));
    }

    function getOrdersService()
    public
    view
    returns (IOrders) {
        return IOrders(augurController.lookup("Orders"));
    }

    // @dev Buy shares
    // @return The result code and the amount of share token bought
    function buyShares(
        uint _amountWETH,
        IShareToken _share, 
        uint _amountShare,
        uint _price, 
        address _receiver,
        address _maker,
        uint _loopLimit) 
    internal
    returns (uint resultCode, uint usedWeth, uint boughtShares) {
        if (_maker != address(this)) {
            // process WETH received
            if (weth.allowance(_maker, address(this)) < _amountWETH) {
                return (ERR_BZX_AUGUR_INSUFFICIENT_WETH_ALLOWANCE, 0, 0);
            }
            require(weth.transferFrom(_maker, address(this), _amountWETH), "AugurAdapter::buyShares: Unable process WETH");            
        }
        
        uint initialBalance = address(this).balance;
        
        weth.withdraw(_amountWETH);

        // do trade, returns remaining amount, boughtShares is used because of Stack too deep. See below
        boughtShares = getTradeService().publicFillBestOrderWithLimit.value(_amountWETH)(
            Order.TradeDirections.Long, 
            _share.getMarket(), 
            _share.getOutcome(), 
            _amountShare, 
            _price, 
            "augur_adapter_buy_trade_group_id", 
            _loopLimit);        
                
        usedWeth = _amountWETH.sub(address(this).balance.sub(initialBalance));
        weth.deposit.value(_amountWETH.sub(usedWeth))();
        
        boughtShares = _amountShare.sub(boughtShares);

        if (_receiver != address(this)) {
            // transfer shares to sender
            require(_share.transfer(_receiver, boughtShares), "AugurAdapter::buyShares: Unable transfer shares");
            // transfer remaining weth to sender
            require(weth.transfer(_receiver, _amountWETH.sub(usedWeth)), "AugurAdapter::buyShares: Unable transfer weth");
        }
        
        emit AugurOracleTrade(Order.TradeDirections.Long, address(_share), usedWeth, boughtShares, _price);

        return (OK, usedWeth, boughtShares);
    }

    // @dev Sell shares
    // @return The result code and the amount of weth received
    function sellShares(
        IShareToken _share, 
        uint _amountShare, 
        uint _price, 
        address _receiver,
        address _maker,
        uint _loopLimit) 
    internal
    returns (uint resultCode, uint usedShares, uint boughtWeth) {  
        // process ShareToken received
        if (_maker != address(this)) {
            if (_share.allowance(_maker, address(this)) < _amountShare) {
                return (ERR_BZX_AUGUR_INSUFFICIENT_STOKEN_ALLOWANCE, 0, 0);
            }

            require(_share.transferFrom(_maker, address(this), _amountShare), "AugurAdapter::sellShares: Unable process shares");
        }
        
        uint initialBalance = address(this).balance;

        // do trade
        uint remainings = getTradeService().publicFillBestOrderWithLimit(
            Order.TradeDirections.Short, 
            _share.getMarket(), 
            _share.getOutcome(), 
            _amountShare, 
            _price, 
            "augur_adapter_trade_group_id", 
            _loopLimit);        

        boughtWeth = address(this).balance.sub(initialBalance);
        weth.deposit.value(boughtWeth)();

        usedShares = _amountShare.sub(remainings);

        if (_receiver != address(this)) {
            // transfer remaining shares to sender
            if (remainings > 0) {
                require(_share.transfer(_receiver, remainings), "AugurAdapter::sellShares: Unable transfer remaining shares");
            }
                
            // transfer remaining WETH to sender        
            require(weth.transfer(_receiver, boughtWeth), "AugurAdapter::sellShares: Unable transfer received WETH to sender");        
        }
        
        emit AugurOracleTrade(Order.TradeDirections.Short, address(_share), boughtWeth, usedShares, _price);

        return (OK, usedShares, boughtWeth);
    }

    // @dev Exchange shares tokens
    // @return The result code and the amount of dest tokens bought
    function swapShares(
        IShareToken _src, 
        uint _srcAmount, 
        IShareToken _dest, 
        uint _maxDestAmount, 
        uint /* _price */, 
        address _receiver, 
        uint _loopLimit) 
    internal
    ensureTokenBalanceUnchanged(weth)
    returns (uint result, uint used, uint bought) {         
        // 1st step: sell src shares token
        (uint rate,) = calculateRate(address(_src), _srcAmount, address(weth), MAX_UINT, _loopLimit);

        (result, , bought) = sellShares(
            _src, 
            _srcAmount, 
            rate.div(RATE_MULTIPLIER), 
            address(this), 
            msg.sender,
            _loopLimit);

        require(result == OK, "AugurAdapter::swapShares: Can't sell shares");

        // 2nd step: buy dest shares token
        (rate,) = calculateRate(address(weth), bought, address(_dest), MAX_UINT, _loopLimit);

        (result, , bought) = buyShares(
            bought, 
            _dest, 
            _maxDestAmount, 
            RATE_MULTIPLIER.div(rate), 
            _receiver, 
            address(this), 
            _loopLimit);

        require(result == OK, "AugurAdapter::swapShares: Can't buy shares");

        used = _srcAmount;

        // 3rd step: verify the rate, make sure that the price was valid
        //require(_price > resultCodeDest.mul(10**18)div(expectedRateSrc), "AugurAdapter::swapShares: Trade is underpriced");
    }    

    // expectedRate = (_dest / _src) * (10**18)
    function calculateRate(
        address _src, 
        uint _srcAmount,
        address _dest, 
        uint _destMaxAmount,
        uint _loopLimit)         
    public // TODO
    view
    returns (uint expectedRate, uint slippageRate) {  
        IOrders ordersService = getOrdersService();

        IShareToken shares = isWETHToken(_src) ? IShareToken(_dest) : IShareToken(_src);
            
        Order.Types orderType = calcOrderType(_src, _dest); 
        bytes32 bestOrderID = ordersService.getBestOrderId(orderType, shares.getMarket(), shares.getOutcome());
        if (bestOrderID == bytes32(0x0)) {
            return (0,0);
        }

        uint srcAmount;
        uint destAmount;
        uint temp;
        do {                  
            slippageRate = ordersService.getPrice(bestOrderID);
            uint amount = ordersService.getAmount(bestOrderID);    
            
            srcAmount += isWETHToken(_src) ? amount.mul(slippageRate) : amount;
            destAmount += isWETHToken(_dest) ? amount.mul(slippageRate) : amount;
            expectedRate += slippageRate.mul(amount);

            bestOrderID = ordersService.getWorseOrderId(bestOrderID);            
        } while(srcAmount < _srcAmount && destAmount < _destMaxAmount && bestOrderID != bytes32(0x0) && (++temp) < _loopLimit);
        
        temp = isWETHToken(_src) ? destAmount : srcAmount;

        if (isShareToken(_src)) {
            return (RATE_MULTIPLIER.mul(expectedRate).div(temp), RATE_MULTIPLIER.mul(slippageRate));
        } else {
            return (RATE_MULTIPLIER.div(expectedRate.div(temp)), RATE_MULTIPLIER.div(slippageRate));
        }        
    }
}