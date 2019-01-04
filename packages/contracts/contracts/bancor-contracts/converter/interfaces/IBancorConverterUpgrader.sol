pragma solidity 0.5.2;
import './IBancorConverter.sol';

/*
    Bancor Converter Upgrader interface
*/
contract IBancorConverterUpgrader {
    function upgrade(bytes32 _version) public;
}
