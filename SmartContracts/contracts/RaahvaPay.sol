// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

 error ZeroAmount();
 error notMinAmount();
 error InvalidExchangeRate();
 error RateNotInitialized();
 error  StaleRate();

contract RaahvaPay{

    uint256 public constant RATE_PRECISION = 1e8;
    uint256 public constant USDC_PRECISION = 1e18;
    uint256 public exchangeRate;
    // Oracle Vars here 
    uint64 private constant MAX_RATE_AGE = 1 days;
    uint64 private lastRateUpdate;
    bool private rateInitialized;


    enum Status {
        QuoteCreated,
        Funded,
        Settled,
        Refunded,
        Expired
    }

    enum RampType {
        OnRamp,
        OffRamp
    }

    struct Quote {
        uint256 pkrAmount;
        uint256 usdcAmount;
        uint256 fee;
        uint256 exchangeRate;
        address user;
        uint64 expireAt;
        uint64 settlementDeadline;
        uint16 feeRate;
        Status status;
        RampType rampType;
    }

    mapping (uint256 => Quote) public quotes;

    function createQuote(uint256 _amount, RampType _rampType) public {
        if(_amount == 0 ) { revert ZeroAmount();}
        if(!rateInitialized){ revert RateNotInitialized();}
        if(block.timestamp - lastRateUpdate > MAX_RATE_AGE) { revert StaleRate();}
        // Validation ToDo
       uint256 pkrAmount;
       uint256 usdcAmount;
       uint256 exchange_rate = exchangeRate;

       if(exchange_rate == 0) {revert InvalidExchangeRate();}

       if(_rampType == RampType.OnRamp) {
           pkrAmount = _amount;
           uint256 precision = USDC_PRECISION * RATE_PRECISION;
           usdcAmount = Math.mulDiv(pkrAmount , precision, exchange_rate);
           if(usdcAmount < 5 ether) {revert notMinAmount();}
        }
       else {
          usdcAmount = _amount;
          if(usdcAmount < 5 ether) {revert notMinAmount();}
          uint256 denominator = (USDC_PRECISION * RATE_PRECISION);
          pkrAmount =  Math.mulDiv(usdcAmount, exchange_rate, denominator);
        }
    }
    
}