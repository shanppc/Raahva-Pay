// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Zeeshan. All rights reserved.
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IRateOracle{
    function getUsdcRate() external view returns(uint256 lastExchangeRate, uint64 lastUpdatedAt);
    function decimals() external view returns(uint8);
}

 error ZeroAmount();
 error NotMinAmount();
 error InvalidExchangeRate();
 error  StaleRate();
 error FutureTime();
 error QuoteExpired();
 error QuoteNotCreated();
 error NotOffRamping();
 error InvalidValue();
 error QuoteNotAvailable();
 error UnAuthorized();
 error TxIdAlreadyUsed();
 error EmptyTxID();
 error InsufficientLiquidity();
 error InvalidQuoteStatus();
 error SignatureExpired();
 error TransferFailed();
 error InvalidRampType();
 error SettlementDeadlinePassed();
 error SettlementDeadlineNotPassed();
 error MaxFeeRate();
 error AlreadyExpired();
 error QuoteNotExpiredYet();
 error ExtensionLimitReached();
 error InvalidExtensionDeadline();
 error InvalidAuthorizationDeadline();
 error InvalidOracleDecimals();
 error InvalidOracleAddress();

contract RaahvaPay is Pausable, Ownable, EIP712{

    uint256 public constant RATE_PRECISION = 1e8;
    uint256 public constant USDC_PRECISION = 1e18;
    uint64 private constant MAX_RATE_AGE = 1 days;
    uint256 public constant BASIS_POINTS = 10000; // 100%
    uint8 public constant MAX_EXTENSIONS = 2;
    uint64 public constant EXTENSION_DURATION = 10 minutes;

    IRateOracle public oracle;
    uint256 private nextQuoteId;
    //Fee and Accounting Vars
    uint16 public feeRate = 100; // 1%
    uint256 public totalFee;
    uint256 public totalCustodied;
    uint256 public totalLiquidity;
    uint256 public reservedLiquidity;
    address public operator;

    bytes32 public constant ONRAMP_PAYMENT_TYPEHASH = keccak256( 
        "OnRampPaymentVerification("
        "uint256 quoteId,"
        "address user,"
        "uint256 pkrAmount,"
        "bytes32 bankTxIdHash,"
        "uint256 deadline)"
    );
    bytes32 public constant OFFRAMP_PAYMENT_TYPEHASH = keccak256( 
        "OffRampPaymentVerification("
        "uint256 quoteId,"
        "address user,"
        "uint256 pkrAmount,"
        "bytes32 bankTxIdHash,"
        "uint256 deadline)"
    );
    bytes32 public constant ONRAMP_EXTENSION_TYPEHASH = keccak256(
        "OnRampSettlementExtension("
        "uint256 quoteId,"
        "address user,"
        "bytes32 bankTxIdHash,"
        "uint64 previousSettlementDeadline,"
        "uint64 newSettlementDeadline,"
        "uint8 extensionCount,"
        "uint64 authorizationDeadline)"
    );    

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
        uint8 extensionCount;
        uint16 feeRate;
        Status status;
        RampType rampType;
    }

    //qouteId => Qoute
    mapping (uint256 => Quote) public quotes;
    // quoteId => bankProff hash
    mapping (uint256 => bytes32) public onRampBankProofs;
    // bankProff hash => is user already used the proof for onRamp 
    mapping(bytes32 => bool) public usedOnRampBankTxIds;
    // bankProff hash => is user already used the proof for OffRamp 
    mapping(bytes32 => bool) public usedOffRampBankTxIds;

    constructor(
        address _oracle, 
        address _operator
        ) 
        EIP712("Raahva Pay", "1") 
        Ownable(msg.sender) 
    {
        if (_oracle == address(0) || _oracle.code.length == 0){
                revert InvalidOracleAddress();
            }

        if (IRateOracle(_oracle).decimals() != 8) {   
            revert InvalidOracleDecimals();  
        }
        oracle = IRateOracle(_oracle);
        operator = _operator;
    }

    event QuoteCreated(
     uint256 quoteId,
     address indexed user,
     uint256 pkrAmount,
     uint256 usdcAmount,
     RampType rampType 
    );
    event QuoteFunded(
     uint256 quoteId,
     address indexed user,
     uint256 fundedValue,
     RampType rampType
    );
    event BankProofSumbitted(
     uint256 quoteId,
     address indexed user,
     bytes32 proofHash
    );
    event LiquiditySupplied(
     address indexed By,
     uint256 Amount
    );
    event OnRampSettled(
     uint256 quoteId,
     address indexed user,
     uint256 amount,
     address indexed Signer
    );
    event OffRampSettled(
     uint256 quoteId,
     address indexed user,
     uint256 amount,
     address indexed signer
    );
    event RefundIssued(
     address indexed user, 
     uint256 refundAmount
    );
    event FeeWithdrawn(
     address indexed owner,
     uint256 feeAmount
    );
    event OperatorChanged(
     address indexed oldOperator,
     address indexed newOperator,
     address changedBy
    );
    event FeeRateChanged(
     uint16 oldFeeRate,
     uint16 newFeeRate,
     address indexed changedBy
    );
    event QuoteGotExpired(uint256 quoteId);
    event OnRampSettlementExtended(
        uint256 indexed quoteId,
        address indexed user,
        uint64 newSettlementDeadline,
        uint8 extensionCount,
        address operator
    );
    event OracleChanged(
        address indexed oldOracle, 
        address indexed newOracle,
        address indexed changedBy
    );


    function createQuote(
          uint256 _amount,
          RampType _rampType
        ) 
        public 
        whenNotPaused 
    {
        if(_amount == 0 ) { revert ZeroAmount();}

        (uint256 exchange_rate, uint64 updatedAt) = oracle.getUsdcRate(); //Fetch Rate from Oracle

        if(exchange_rate == 0 ) {revert InvalidExchangeRate();}
        if(block.timestamp < updatedAt){ revert FutureTime();}
        if(block.timestamp - updatedAt > MAX_RATE_AGE) { revert StaleRate();}

        uint256 pkrAmount;
        uint256 usdcAmount;

        if (_rampType == RampType.OnRamp) {
          pkrAmount = _amount;

          uint256 precision = USDC_PRECISION * RATE_PRECISION;

          usdcAmount = Math.mulDiv( pkrAmount, precision, exchange_rate );

          if (usdcAmount < 5 ether) { revert NotMinAmount(); }
          if (reservedLiquidity > totalLiquidity) { revert InsufficientLiquidity();}
          // available liquidity = totalLiquidity - reservedLiquidity.
          if (usdcAmount > totalLiquidity - reservedLiquidity) { revert InsufficientLiquidity();}

          reservedLiquidity += usdcAmount;
        } 
        else if (_rampType == RampType.OffRamp) {
           usdcAmount = _amount;

          if (usdcAmount < 5 ether){ revert NotMinAmount();} 
        }
        else { 
            revert InvalidRampType();
        }

        uint16 quoteFeeRate = feeRate;
        // Calculate the fee after usdcAmount has been assigned.
        uint256 fee = Math.mulDiv( usdcAmount, quoteFeeRate, BASIS_POINTS);

        // OffRamp: calculate PKR from the net USDC amount.
        if (_rampType == RampType.OffRamp) {
            uint256 netUsdcAmount = usdcAmount - fee;

            uint256 denominator = USDC_PRECISION * RATE_PRECISION;
            pkrAmount = Math.mulDiv( netUsdcAmount, exchange_rate, denominator );
        }
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
       extensionCount: 0,
       feeRate: quoteFeeRate,
       status: Status.QuoteCreated,
       rampType: _rampType });

     emit QuoteCreated( quoteId, msg.sender, pkrAmount, usdcAmount, _rampType );
    }

    function fundOffRampQuote(uint256 _qouteId) 
        external 
        payable 
        whenNotPaused 
    {
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

    function submitOnRampBankProof(
          uint256 _quoteId, 
          string calldata _bankTxId
        ) 
         external 
         whenNotPaused 
    {
        Quote storage quote = quotes[_quoteId];
        if(quote.usdcAmount == 0) {revert QuoteNotAvailable();}
        if(quote.status != Status.QuoteCreated) {revert QuoteNotCreated();}
        if(quote.user != msg.sender) {revert UnAuthorized();}
        if(quote.rampType != RampType.OnRamp) {revert InvalidRampType();}
        if(block.timestamp > quote.expireAt) {revert QuoteExpired();}
        if(bytes(_bankTxId).length == 0){ revert EmptyTxID();}

        bytes32 bankTxIdHash = keccak256(bytes(_bankTxId));

        onRampBankProofs[_quoteId] = bankTxIdHash;

        quote.status = Status.ProofSubmitted;
        quote.settlementDeadline = uint64(block.timestamp + 10 minutes);

        emit BankProofSumbitted(_quoteId, msg.sender, bankTxIdHash);
    }

    function verifyAndSettleOnRamp(
        uint256 _quoteId, 
        bytes calldata _signature 
        ) 
        external 
        whenNotPaused 
    {
        Quote storage quote = quotes[_quoteId];
        if (quote.usdcAmount == 0) {revert QuoteNotAvailable(); }
        if (quote.status != Status.ProofSubmitted) { revert InvalidQuoteStatus(); }
        if (quote.rampType != RampType.OnRamp) { revert InvalidRampType(); }
        if (block.timestamp > quote.settlementDeadline) { revert SignatureExpired(); }

        bytes32 bankTxIdHash = onRampBankProofs[_quoteId];

        if (usedOnRampBankTxIds[bankTxIdHash]) {revert TxIdAlreadyUsed();}

        bytes32 structHash = keccak256(
            abi.encode(
                ONRAMP_PAYMENT_TYPEHASH,
                _quoteId, 
                quote.user,
                quote.pkrAmount,
                bankTxIdHash,
                quote.settlementDeadline
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(digest, _signature);

        if (signer != operator) { revert UnAuthorized(); }

        if (quote.usdcAmount > reservedLiquidity) { revert InsufficientLiquidity(); }

        usedOnRampBankTxIds[bankTxIdHash] = true; // consumed tx id
        uint256 payout = quote.usdcAmount - quote.fee;
        quote.status = Status.Settled;
        totalLiquidity -= quote.usdcAmount;
        reservedLiquidity -= quote.usdcAmount;
        totalFee += quote.fee;

        // release USDC to the user
        (bool success, ) = payable(quote.user).call{value: payout}("");
        if (!success) {revert TransferFailed(); }

        emit OnRampSettled( _quoteId, quote.user, payout, signer );
    }

    function settleOffRampQuote( 
        uint256 _quoteId, 
        bytes32 _bankTxIdHash, 
        bytes calldata _signature 
        ) 
        external 
        whenNotPaused 
    {
        Quote storage quote = quotes[_quoteId];

        if(quote.usdcAmount == 0) { revert QuoteNotAvailable(); }
        if(quote.status != Status.Funded) { revert InvalidQuoteStatus(); }
        if(quote.rampType != RampType.OffRamp) { revert InvalidRampType(); }
        if(block.timestamp > quote.settlementDeadline) {revert SettlementDeadlinePassed();}
        if(_bankTxIdHash == bytes32(0)){ revert EmptyTxID(); }
        if(usedOffRampBankTxIds[_bankTxIdHash]){ revert TxIdAlreadyUsed();}

        bytes32 structHash = keccak256(
            abi.encode(
                OFFRAMP_PAYMENT_TYPEHASH,
                _quoteId, quote.user, 
                quote.pkrAmount, 
                _bankTxIdHash, 
                quote.settlementDeadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, _signature);

        if (signer != operator) { revert UnAuthorized(); }
        
        usedOffRampBankTxIds[_bankTxIdHash] = true;
        totalCustodied -= quote.usdcAmount;
        totalLiquidity += quote.usdcAmount - quote.fee;
        totalFee += quote.fee;
        quote.status = Status.Settled;

        emit OffRampSettled(_quoteId, quote.user, quote.pkrAmount, signer);

    }

    function refundQuote(uint256 _quoteId) external 
    {
        Quote storage quote = quotes[_quoteId];
        if(quote.usdcAmount < 5 ether){ revert QuoteNotAvailable(); }
        if(quote.user != msg.sender){ revert UnAuthorized(); }
        if(quote.rampType != RampType.OffRamp){revert InvalidRampType(); }
        if(quote.status != Status.Funded){ revert InvalidQuoteStatus(); }
        if(quote.settlementDeadline >= block.timestamp)
        { 
            revert SettlementDeadlineNotPassed();
        }

        quote.status = Status.Refunded;
        totalCustodied -= quote.usdcAmount;

        (bool ok,) = quote.user.call{value: quote.usdcAmount}("");
        if(!ok){revert TransferFailed();}

        emit RefundIssued(msg.sender, quote.usdcAmount);
    } 

    function supplyLiquidity() external payable {
        if(msg.value == 0) {revert ZeroAmount();}
        totalLiquidity += msg.value;

        emit LiquiditySupplied(msg.sender, msg.value);
    }

    function expireQuote(uint256 _quoteId) external 
    {
        Quote storage quote = quotes[_quoteId];
        if(quote.usdcAmount == 0){revert QuoteNotAvailable();}
        if(quote.status == Status.Expired){revert AlreadyExpired();}
        if(quote.user != msg.sender){ revert UnAuthorized();}
        if(
              quote.status == Status.QuoteCreated  
              && quote.expireAt > block.timestamp
            ) 
        { 
            revert QuoteNotExpiredYet();
        } 
        if( 
            quote.settlementDeadline >= block.timestamp
           ) 
        { 
            revert SettlementDeadlineNotPassed();
        }
        if(
             quote.status == Status.Settled 
             || quote.status == Status.Refunded 
             || quote.status == Status.Funded 
             || quote.status == Status.ProofSubmitted 
            ) 
        {
            revert InvalidQuoteStatus(); 
        }
        if(quote.rampType == RampType.OnRamp) {
            reservedLiquidity -= quote.usdcAmount;
        }

        quote.status = Status.Expired;

        emit QuoteGotExpired(_quoteId);
    }

    function extendOnRampSettlement(
            uint256 _quoteId,
            uint64 _newSettlementDeadline,
            uint64 _authorizationDeadline,
            bytes calldata _signature
        )
    external
    whenNotPaused
    {
        Quote storage quote = quotes[_quoteId];

        if (quote.usdcAmount == 0) { revert QuoteNotAvailable();}

        if (quote.status != Status.ProofSubmitted) { revert InvalidQuoteStatus(); }

        if (quote.rampType != RampType.OnRamp) { revert InvalidRampType(); }

        if (block.timestamp <= quote.settlementDeadline) {
            revert SettlementDeadlineNotPassed();
        }

        if (quote.extensionCount >= MAX_EXTENSIONS) {
          revert ExtensionLimitReached();
        }

        if (
                _newSettlementDeadline <= block.timestamp ||
                _newSettlementDeadline > block.timestamp + EXTENSION_DURATION
            ) 
        {
            revert InvalidExtensionDeadline();
        }

        if (
                block.timestamp > _authorizationDeadline ||
                _authorizationDeadline > block.timestamp + EXTENSION_DURATION
            ) 
        {
         revert InvalidAuthorizationDeadline();
        }

        bytes32 bankTxIdHash = onRampBankProofs[_quoteId];

        uint8 nextExtensionCount = quote.extensionCount + 1;

        bytes32 structHash = keccak256(
            abi.encode(
                ONRAMP_EXTENSION_TYPEHASH,
                _quoteId,
                quote.user,
                bankTxIdHash,
                quote.settlementDeadline,
                _newSettlementDeadline,
                nextExtensionCount,
                _authorizationDeadline
            )
        );  

        bytes32 digest = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(digest, _signature);

        if (signer != operator) {revert UnAuthorized(); }

        quote.settlementDeadline = _newSettlementDeadline;
        quote.extensionCount = nextExtensionCount;

        emit OnRampSettlementExtended(
            _quoteId,
            quote.user,
            quote.settlementDeadline,
            nextExtensionCount,
            signer
        );
    }

    // Owner only Functions
    function withdrawTotalFee() external onlyOwner 
    {
        uint256 amount = totalFee;
        if(amount == 0) {revert ZeroAmount();}

        totalFee = 0;

        (bool ok,) = owner().call{value:amount}("");
        if(!ok){revert TransferFailed();}

        emit FeeWithdrawn(msg.sender, amount);
    } 

    function pause() external onlyOwner { _pause(); }

    function unpause() external onlyOwner { _unpause(); }

    function changeOperator(address _newOperator) external onlyOwner {
        address oldOperator = operator;
        operator = _newOperator;
        emit OperatorChanged(oldOperator, operator, msg.sender);
    }

    function changeFeeRate(uint16 _newFeeRate) external onlyOwner {
        if(_newFeeRate > 500){ revert MaxFeeRate();}
        uint16 oldFeeRate = feeRate;

        feeRate = _newFeeRate; 

        emit FeeRateChanged(oldFeeRate, feeRate, msg.sender);
    }

    function chnageOracle(address _newOracle) external onlyOwner {
        if (_newOracle == address(0) || _newOracle.code.length == 0){
                revert InvalidOracleAddress();
        }

        if (IRateOracle(_newOracle).decimals() != 8) {   
            revert InvalidOracleDecimals();  
        } 

        address oldOracle =  address(oracle);

        oracle = IRateOracle(_newOracle);

        emit OracleChanged(oldOracle, _newOracle, msg.sender);
    }

}