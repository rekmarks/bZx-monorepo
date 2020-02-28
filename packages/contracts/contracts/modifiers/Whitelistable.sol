
pragma solidity 0.5.3;


contract Whitelistable {

    modifier onlyWhitelist() {
        require(_isWhitelisted(msg.sender), "unauthorized");
        _;
    }

    function _isWhitelisted(
        address addr)
        internal
        view
        returns (bool)
    {
        //keccak256("BZX_CallerWhitelist")
        bytes32 slot = keccak256(abi.encodePacked(addr, uint256(0x5f860f505ab4212ecce783dc8a4f8f352dd1ac760adcede3abfff9062e6bc51f)));
        bool isWhitelisted;
        assembly {
            isWhitelisted := sload(slot)
        }
        return isWhitelisted;
    }
}
