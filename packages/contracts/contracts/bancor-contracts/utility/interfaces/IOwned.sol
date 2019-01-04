pragma solidity 0.5.2;

/*
    Owned contract interface
*/
contract IOwned {
    // this function isn't abstract since the compiler emits automatically generated getter functions as external
    address public owner;

    function transferOwnership(address _newOwner) public;
    function acceptOwnership() public;
}
