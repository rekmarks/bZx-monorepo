pragma solidity 0.5.2;

import "./Router.sol";
import "../../openzeppelin-solidity/Ownable.sol";

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