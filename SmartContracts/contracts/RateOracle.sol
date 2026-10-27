// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;


error InvalidRate();
error UnAuthorized();
contract Oracle {

    uint256 public exchangeRate;  // pkr per usdc 
    uint64 public updatedAt;
    address public immutable owner;
    uint8 public constant decimals = 8;

    constructor() {
        owner = msg.sender;
    }

    event PriceUpdated(uint256 prevRate, uint256 updatedRate, uint64 updatedAt, address indexed updatedBy);

    function updateRate(uint256 _newRate) public onlyOwner {
        if(_newRate == 0) {revert InvalidRate(); }

        uint256 prevRate = exchangeRate;
        exchangeRate = _newRate;
        updatedAt = uint64(block.timestamp);

        emit PriceUpdated(prevRate, exchangeRate, updatedAt, msg.sender);
    }

    function getUsdcRate() public view returns(uint256 lastExchangeRate, uint64 lastUpdatedAt) {
        return (exchangeRate, updatedAt);
    }

    modifier onlyOwner() {
        if(msg.sender != owner) { revert UnAuthorized();}
        _;
    }
    
}