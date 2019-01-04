pragma solidity 0.5.2;
import './IERC20Token.sol';
import '../../utility/interfaces/ITokenHolder.sol';

/*
    Ether Token interface
*/
contract IEtherToken is ITokenHolder, IERC20Token {
    function deposit() public payable;
    function withdraw(uint256 _amount) public;
    function withdrawTo(address payable _to, uint256 _amount) public;
}
