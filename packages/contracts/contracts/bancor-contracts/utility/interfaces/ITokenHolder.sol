pragma solidity 0.5.2;
import './IOwned.sol';
import '../../token/interfaces/IERC20Token.sol';

/*
    Token Holder interface
*/
contract ITokenHolder is IOwned {
    function withdrawTokens(IERC20Token _token, address _to, uint256 _amount) public;
}
