pragma solidity 0.5.2;

/*
    Bancor Gas Price Limit interface
*/
contract IBancorGasPriceLimit {
    uint256 public gasPrice = 0 wei;
    function validateGasPrice(uint256) public view;
}
