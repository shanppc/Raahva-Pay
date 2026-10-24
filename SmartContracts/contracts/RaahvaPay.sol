// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IRateOracle{
    function getUsdcRate() external view returns(uint256 lastExchangeRate, uint64 lastUpdatedAt);
    function decimals() external view returns(uint8);
}

 error ZeroAmount();
 error notMinAmount();
 error InvalidExchangeRate();
 error RateNotInitialized();
 error  StaleRate();
 error FutureTime();
 error QuoteExpired();
 error QuoteNotCreated();
 error NotOffRamping();
 error InvalidValue();
 error QuoteNotAvailable();
 error UnAuthorized();
 error NotOnRamping();
 error TxIsAlreadyUsed();
 error EmptyTxID();

contract RaahvaPay{

    uint256 public constant RATE_PRECISION = 1e8;
    uint256 public constant USDC_PRECISION = 1e18;
    // Oracle Vars here 
    uint64 private constant MAX_RATE_AGE = 1 days;
    IRateOracle public oracle;
    uint256 private nextQuoteId;
    //Fee and Accounting Vars
    uint256 public constant BASIS_POINTS = 10000; // 100%
    uint16 public feeRate = 100; // 1%
    uint256 public totalFee;
    uint256 public totalCustodied;

    enum Status {
        QuoteCreated,
        Funded,
        ProofSubmitted,
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

    constructor(address _oracle) {
        oracle = IRateOracle(_oracle);
    }
     //qouteId => Qoute
    mapping (uint256 => Quote) public quotes;
    // quoteId => bankProff hash
    mapping (uint256 => bytes32) public bankProofs;
    // bankProff hash => is user already used the proof
    mapping(bytes32 => bool ) public usedBankTxIds;

    event QuoteCreated(uint256 QuoteId,address user, uint256 PkrAmount, uint256 UsdcAmount, RampType rampType );
    event QuoteFunded(uint256 QuoteId, address user,uint256 FundedValue, RampType rampType);
    event BankProofSumbitted(uint256 QuoteId, address user, bytes32 proofHash);

    function createQuote(uint256 _amount, RampType _rampType) public {
        if(_amount == 0 ) { revert ZeroAmount();}
        (uint256 exchange_rate, uint64 updatedAt) = oracle.getUsdcRate(); 
        if(exchange_rate == 0 ) {revert InvalidExchangeRate();}
        if(block.timestamp < updatedAt){ revert FutureTime();}
        if(block.timestamp - updatedAt > MAX_RATE_AGE) { revert StaleRate();}

        uint256 pkrAmount;
        uint256 usdcAmount;

        if (_rampType == RampType.OnRamp) {
          pkrAmount = _amount;

          uint256 precision = USDC_PRECISION * RATE_PRECISION;

          usdcAmount = Math.mulDiv( pkrAmount, precision, exchange_rate );

          if (usdcAmount < 5 ether) { revert notMinAmount(); }
        } 
        else if (_rampType == RampType.OffRamp) {
           usdcAmount = _amount;

           if (usdcAmount < 5 ether) {revert notMinAmount();}

           uint256 denominator = USDC_PRECISION * RATE_PRECISION;

           // Calculate PKR from the gross USDC amount.
           pkrAmount = Math.mulDiv( usdcAmount, exchange_rate, denominator );
        }

     // Snapshot the fee configuration for this quote.
     uint16 quoteFeeRate = feeRate;

     // Calculate the fee in USDC base units.
     uint256 fee = Math.mulDiv( usdcAmount, quoteFeeRate, BASIS_POINTS );

     // Generate a unique quote ID.
     uint256 quoteId = nextQuoteId++;
         
     // Store the quote.
     quotes[quoteId] = Quote({
       pkrAmount: pkrAmount,
       usdcAmount: usdcAmount,
       fee: fee,
       exchangeRate: exchange_rate,
       user: msg.sender,
       expireAt: uint64(block.timestamp + 10 minutes),
       settlementDeadline: 0,
       feeRate: quoteFeeRate,
       status: Status.QuoteCreated,
       rampType: _rampType });

     emit QuoteCreated( quoteId, msg.sender, pkrAmount, usdcAmount, _rampType );
    }

    function fundOffRampQoute(uint256 _qouteId) external payable{
        Quote storage quote = quotes[_qouteId];
        if(quote.usdcAmount == 0) {revert QuoteNotAvailable();}
        if(block.timestamp > quote.expireAt) { revert QuoteExpired();}
        if(quote.status != Status.QuoteCreated) { revert QuoteNotCreated();}
        if(quote.rampType != RampType.OffRamp) { revert NotOffRamping();}
        if(msg.value != quote.usdcAmount ){revert InvalidValue();}
        if(quote.user != msg.sender) { revert UnAuthorized();} 

        quote.status = Status.Funded;
        quote.settlementDeadline = uint64(block.timestamp + 10 minutes);

        totalCustodied += msg.value;

        emit QuoteFunded(_qouteId, msg.sender, msg.value, quote.rampType);
    }

    function sumbitBankProof(uint256 _quoteId, string calldata _bankTxId) external {
        Quote storage quote = quotes[_quoteId];
        if(quote.usdcAmount == 0) {revert QuoteNotAvailable();}
        if(quote.status != Status.QuoteCreated) {revert QuoteNotCreated();}
        if(quote.user != msg.sender) {revert UnAuthorized();}
        if(quote.rampType != RampType.OnRamp) {revert NotOnRamping();}
        if(block.timestamp > quote.expireAt) {revert QuoteExpired();}
        if(bytes(_bankTxId).length == 0){ revert EmptyTxID();}

        bytes32 bankTxIdHash = keccak256(bytes(_bankTxId));

        if(usedBankTxIds[bankTxIdHash]){ revert TxIsAlreadyUsed();}

        bankProofs[_quoteId] = bankTxIdHash;
        usedBankTxIds[bankTxIdHash] = true;

        quote.status = Status.ProofSubmitted;

        emit BankProofSumbitted(_quoteId, msg.sender, bankTxIdHash);
    }
    
}