pragma solidity 0.4.24;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
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

        require(ERC20(_cash).approve(augurController.getAugur(), ETERNAL_APPROVAL_VALUE), "Failed to set unlimited allowance");
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
    returns (uint, uint) {        
        if(isWETHToken(_src) && isShareToken(_dest)) {
            return buyShares(_srcAmount, IShareToken(_dest), _maxDestAmount, _price, _receiver, _loopLimit);
        } else if (isShareToken(_src) && isWETHToken(_dest)) {
            return sellShares(IShareToken(_src), _srcAmount, _maxDestAmount, _price, _receiver, _loopLimit);
        }
        
        return (ERR_BZX_AUGUR_UNSUPPORTED_TOKEN, 0);                      
    }
    
    function getExpectedRate(
        address _src, 
        address _dest, 
        uint _shareAmount,
        uint _loopLimit)         
    public
    view
    returns (uint expectedRate, uint slippageRate) {  
        IOrders ordersService = getOrdersService();

        IShareToken shares = isShareToken(_src) ? IShareToken(_src) : IShareToken(_dest);
            
        Order.Types orderType = calcOrderType(_src, _dest); 
        bytes32 bestOrderID = ordersService.getBestOrderId(orderType, shares.getMarket(), shares.getOutcome());
        if (bestOrderID == bytes32(0x0)) {
            return (0,0);
        }

        uint totalAmount;
        uint volume;
        uint loop;
        do {                  
            slippageRate = ordersService.getPrice(bestOrderID);
            uint amount = ordersService.getAmount(bestOrderID);    
            
            totalAmount += amount;
            volume += slippageRate.mul(amount);

            bestOrderID = ordersService.getWorseOrderId(bestOrderID);            
        } while(totalAmount < _shareAmount && bestOrderID != bytes32(0x0) && (++loop) < _loopLimit);
        
        return (volume.div(totalAmount), slippageRate);
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
        if (_token == address(0x0)) {
            return false;
        }

        // TODO: ahiatsevich: find no so dirty way to perform this check
        _token.call.gas(4999)(abi.encodeWithSignature("getTypeName()")); 
        assembly {
            switch returndatasize
            case 32 {
                result := not(0)
            }
            default {
                result := 0
            }
        }

        result = result && IShareToken(_token).getTypeName() == bytes32("ShareToken");
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

    function buyShares(
        uint _amountWETH, 
        IShareToken _share, 
        uint _amountShare, 
        uint _price, 
        address _receiver,
        uint _loopLimit) 
    internal
    returns (uint, uint) {
        // process WETH received
        if (weth.allowance(msg.sender, address(this)) < _amountWETH) {
            return (ERR_BZX_AUGUR_INSUFFICIENT_WETH_ALLOWANCE, 0);
        }
        require(weth.transferFrom(msg.sender, address(this), _amountWETH), "AugurAdapter::buyShares: Unable process WETH");
        weth.withdraw(_amountWETH);

        // do trade
        uint256 remainingShare = getTradeService().publicFillBestOrderWithLimit.value(_amountWETH)(
                                                    Order.TradeDirections.Long, 
                                                    _share.getMarket(), 
                                                    _share.getOutcome(), 
                                                    _amountShare, 
                                                    _price, 
                                                    "augur_adapter_trade_group_id", 
                                                    _loopLimit);        

        // transfer bought shares to sender
        require(_share.transfer(_receiver, _amountShare.sub(remainingShare)), "AugurAdapter::buyShares: Unable transfer shares");

        emit AugurOracleTrade(Order.TradeDirections.Long, _share, _amountWETH, _amountShare.sub(remainingShare), _price);

        return (OK, remainingShare);
    }

    function sellShares(
        IShareToken _share, 
        uint _amountShare, 
        uint _amountWETH, 
        uint _price, 
        address _receiver,
        uint _loopLimit) 
    internal
    returns (uint errorCode, uint remainingShare) {  
        // process ShareToken received
        if (_share.allowance(msg.sender, address(this)) < _amountShare) {
            return (ERR_BZX_AUGUR_INSUFFICIENT_STOKEN_ALLOWANCE, 0);
        }

        require(_share.transferFrom(msg.sender, address(this), _amountShare), "AugurAdapter::sellShares: Unable process shares");

        uint initialBalance = address(this).balance;

        // do trade
        remainingShare = getTradeService().publicFillBestOrderWithLimit(
                                    Order.TradeDirections.Short, 
                                    _share.getMarket(), 
                                    _share.getOutcome(), 
                                    _amountShare, 
                                    _price, 
                                    "augur_adapter_trade_group_id", 
                                    _loopLimit);        

        // transfer remaining shares to sender
        require(_share.transfer(_receiver, remainingShare), "AugurAdapter::sellShares: Unable transfer remaining shares");

        // transfer remaining shares to sender
        uint receivedValue = address(this).balance.sub(initialBalance);
        weth.deposit.value(receivedValue)();
        require(weth.transfer(_receiver, receivedValue), "AugurAdapter::sellShares: Unable transfer received WETH to sender");
        
        emit AugurOracleTrade(Order.TradeDirections.Short, _share, _amountWETH, _amountShare.sub(remainingShare), _price);

        return (OK, remainingShare);
    }
}