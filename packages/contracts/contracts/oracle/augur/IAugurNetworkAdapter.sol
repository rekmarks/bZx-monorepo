pragma solidity 0.4.24;

library Order {
    enum Types {
        Bid, Ask
    }
    enum TradeDirections {
        Long, Short
    }
}

contract IAugurNetworkAdapter {
    uint256 public constant ETERNAL_APPROVAL_VALUE = 2 ** 256 - 1;    

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
    returns (uint errorCode, uint remaining);
    
    /// @notice Returns expected rate for given tokens
    function getExpectedRate(
        address src, 
        address dest, 
        uint shareAmount, 
        uint loopLimit) 
    public 
    view 
    returns (uint expectedRate, uint slippageRate);
 
    function isShareToken(address token) 
    public 
    view 
    returns (bool result);
}