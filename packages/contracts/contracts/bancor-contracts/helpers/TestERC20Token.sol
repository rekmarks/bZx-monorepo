pragma solidity 0.5.2;
import '../token/ERC20Token.sol';

/*
    Test token with predefined supply
*/
contract TestERC20Token is ERC20Token {
    constructor(string memory _name, string memory _symbol, uint256 _supply)
        public
        ERC20Token(_name, _symbol, 0)
    {
        totalSupply = _supply;
        balanceOf[msg.sender] = _supply;
    }
}