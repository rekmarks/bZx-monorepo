pragma solidity 0.4.24;

import "./Router.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";

contract AugurOracleProxy is Router, Ownable {   
    address private backendAddress;

    function setBackend(address _backend)
    public
    onlyOwner {
        backendAddress = _backend;
    }

    function backend() 
    internal 
    view 
    returns (address) {
        return backendAddress;
    }
}