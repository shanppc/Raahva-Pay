// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

error RateOutOfBounds();

contract Oracle is Ownable2Step {

    uint8 public constant decimals = 8;
    uint256 public exchangeRate; // PKR per USDC
    uint64 public updatedAt;

    constructor(address initialOwner)
        Ownable(initialOwner)
    {}

    event PriceUpdated(
        uint256 prevRate,
        uint256 updatedRate,
        uint64 updatedAt,
        address indexed updatedBy
    );

    function updateRate(uint256 _newRate)
        public
        onlyOwner
    {
        if (_newRate < 100e8 || _newRate > 1000e8) {revert RateOutOfBounds();}

        uint256 prevRate = exchangeRate;

        exchangeRate = _newRate;
        updatedAt = uint64(block.timestamp);

        emit PriceUpdated( prevRate, exchangeRate, updatedAt, msg.sender);
    }

    function getUsdcRate()
        public
        view
        returns (uint256 lastExchangeRate, uint64 lastUpdatedAt)
    {
        return (exchangeRate, updatedAt);
    }
    
}