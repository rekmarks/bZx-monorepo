pragma solidity 0.4.24;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";

contract ITyped {
    function getTypeName() public view returns (bytes32);
}

contract IShareToken is ITyped, ERC20 {
    function initialize(IMarket _market, uint256 _outcome) external returns (bool);
    function createShares(address _owner, uint256 _amount) external returns (bool);
    function destroyShares(address, uint256 balance) external returns (bool);
    function getMarket() external view returns (IMarket);
    function getOutcome() external view returns (uint256);
    function trustedOrderTransfer(address _source, address _destination, uint256 _attotokens) public returns (bool);
    function trustedFillOrderTransfer(address _source, address _destination, uint256 _attotokens) public returns (bool);
    function trustedCancelOrderTransfer(address _source, address _destination, uint256 _attotokens) public returns (bool);
}

library Order {
    enum Types {
        Bid, Ask
    }
    enum TradeDirections {
        Long, Short
    }
}

contract ICash is ERC20 {
    function depositEther() external payable returns(bool);
    function depositEtherFor(address _to) external payable returns(bool);
    function withdrawEther(uint256 _amount) external returns(bool);
    function withdrawEtherTo(address _to, uint256 _amount) external returns(bool);
    function withdrawEtherToIfPossible(address _to, uint256 _amount) external returns (bool);
}

contract IWETH is ERC20 {
    function deposit() external payable;    
    function withdraw(uint wad) public;
}

interface IController {
    function lookup(bytes32 _key) external view returns(address);  
    function getAugur() external view returns (address);
}

interface ITrade {    
    function publicFillBestOrder(
        Order.TradeDirections _direction, 
        IMarket _market, 
        uint256 _outcome, 
        uint256 _amount, 
        uint256 _price, 
        uint256 _tradeGroupID) 
        external 
        payable
        returns (uint256);    

    function publicFillBestOrderWithLimit(
        Order.TradeDirections _direction, 
        IMarket _market, 
        uint256 _outcome, 
        uint256 _fxpAmount, 
        uint256 _price, 
        bytes32 _tradeGroupId, 
        uint256 _loopLimit) 
        external 
        payable 
        returns (uint256);
}

contract IMarket  {
    enum MarketType {
        YES_NO,
        CATEGORICAL,
        SCALAR
    }

    //function getFeeWindow() public view returns (IFeeWindow);
    function getNumberOfOutcomes() public view returns (uint256);
    function getNumTicks() public view returns (uint256);
    function getDenominationToken() public view returns (ICash);
    function getShareToken(uint256 _outcome)  public view returns (IShareToken);
    function isInvalid() public view returns (bool);    
}

contract IOrders {    
    function getMarket(bytes32 _orderId) public view returns (IMarket);
    function getOrderType(bytes32 _orderId) public view returns (Order.Types);
    function getOutcome(bytes32 _orderId) public view returns (uint256);
    function getAmount(bytes32 _orderId) public view returns (uint256);
    function getPrice(bytes32 _orderId) public view returns (uint256);
    function getBetterOrderId(bytes32 _orderId) public view returns (bytes32);
    function getWorseOrderId(bytes32 _orderId) public view returns (bytes32);
    function getBestOrderId(Order.Types _type, IMarket _market, uint256 _outcome) public view returns (bytes32);
    function getWorstOrderId(Order.Types _type, IMarket _market, uint256 _outcome) public view returns (bytes32);
    function getLastOutcomePrice(IMarket _market, uint256 _outcome) public view returns (uint256);    
    function isBetterPrice(Order.Types _type, uint256 _price, bytes32 _orderId) public view returns (bool);
    function isWorsePrice(Order.Types _type, uint256 _price, bytes32 _orderId) public view returns (bool);
}

contract IAugurNetworkAdapter {    
    uint public constant MAX_UINT = 2**256 - 1;
    uint public constant RATE_MULTIPLIER = 10**18;

    uint public constant OK = 1;
    uint public constant ERR_BZX_AUGUR_UNSUPPORTED_TOKEN = 420001;
    uint public constant ERR_BZX_AUGUR_INSUFFICIENT_WETH_ALLOWANCE = 420002;
    uint public constant ERR_BZX_AUGUR_INSUFFICIENT_STOKEN_ALLOWANCE = 420003;

    event AugurOracleTrade(
        Order.TradeDirections direction, 
        address share,        
        uint256 value, 
        uint256 shareAmount, 
        uint256 price
    );

    /// @notice Trade tokens
    function trade(
        address src, 
        uint srcAmount, 
        address dest, 
        uint maxDestAmount, 
        uint price,
        address receiver,
        uint loopLimit)             
    public
    returns (uint errorCode, uint used, uint remaining);
    
    function getBuyRate(
        address _share,  
        uint _shareAmount,
        uint _loopLimit)         
    public
    view
    returns (uint expectedRate, uint slippageRate);

    function getSellRate(
        address _share,  
        uint _shareAmount,
        uint _loopLimit)         
    public
    view
    returns (uint expectedRate, uint slippageRate);
    
    function getSwapRate(
        address _shareSrc,  
        uint _shareSrcAmount,
        address _shareDest,  
        uint _loopLimit)         
    public
    view
    returns (uint expectedRate, uint slippageRate);
 
    function getVolume(
        address _shareToken, 
        Order.Types _orderType,
        uint _loopLimit)         
    public
    view
    returns(uint);

    function getShareTokens(
        address _market)         
    public
    view
    returns (address []);

    function isShareToken(address token) 
    public 
    view 
    returns (bool result);
}