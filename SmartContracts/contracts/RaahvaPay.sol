// SPDX-License-Identifier: UNLICENSED
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
 error TxIsAlreadyUsed();
 error EmptyTxID();
 error InsufficientLiquidity();
 error InvalidQuoteStatus();
 error SignatureExpired();
 error TransferFailed();
 error InvalidRampType();
 error SettlementDeadlinePassed();
 error InvalidSignatureDeadline();
 error SettlementDeadlineNotPass();
 error MaxFeeRate();

contract RaahvaPay is Pausable, Ownable, EIP712{

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
    uint256 public totalLiquidity;
    address public operator;

    bytes32 public constant ONRAMP_PAYMENT_TYPEHASH = keccak256( "OnRampPaymentVerification(uint256 quoteId,address user,uint256 pkrAmount,bytes32 bankTxIdHash,uint256 deadline)");
    bytes32 public constant OFFRAMP_PAYMENT_TYPEHASH = keccak256( "OffRampPaymentVerification(uint256 quoteId,address user,uint256 pkrAmount,bytes32 bankTxIdHash,uint256 deadline)");

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

    constructor(address _oracle, address _operator) EIP712("Raahva Pay", "1") Ownable(msg.sender) {
        oracle = IRateOracle(_oracle);
        operator = _operator;
    }
     //qouteId => Qoute
    mapping (uint256 => Quote) public quotes;
    // quoteId => bankProff hash
    mapping (uint256 => bytes32) public bankProofs;
    // bankProff hash => is user already used the proof
    mapping(bytes32 => bool ) public usedBankTxIds;

    event QuoteCreated(uint256 QuoteId,address indexed  user, uint256 PkrAmount, uint256 UsdcAmount, RampType rampType );
    event QuoteFunded(uint256 QuoteId, address indexed user,uint256 FundedValue, RampType rampType);
    event BankProofSumbitted(uint256 QuoteId, address indexed user, bytes32 proofHash);
    event LiquiditySupplied(address indexed By, uint256 Amount);
    event OnRampSettled(uint256 QuoteId, address indexed user, uint256 Amount, address indexed Signer);
    event OffRampSettled(uint256 QuoteId, address indexed user, uint256 Amount, address indexed Signer);
    event RefundIssued(address indexed user, uint256 RefundAmount);
    event feeWithdrawn(address indexed Owner, uint256 FeeAmount);
    event operatorChanged(address indexed OldOperator, address indexed NewOperator, address changedBy);
    event feeRateChanged(uint16 OldFeeRate, uint16 NewFeeRate, address indexed changedBy);

    function createQuote(uint256 _amount, RampType _rampType) public whenNotPaused {
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

          if (usdcAmount < 5 ether) { revert notMinAmount(); }
          if (usdcAmount > totalLiquidity) { revert InsufficientLiquidity();}
        } 
        else if (_rampType == RampType.OffRamp) {
           usdcAmount = _amount;

          if (usdcAmount < 5 ether){ revert notMinAmount();} 
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
       feeRate: quoteFeeRate,
       status: Status.QuoteCreated,
       rampType: _rampType });

     emit QuoteCreated( quoteId, msg.sender, pkrAmount, usdcAmount, _rampType );
    }

    function fundOffRampQoute(uint256 _qouteId) external payable whenNotPaused {
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

    function sumbitBankProof(uint256 _quoteId, string calldata _bankTxId) external whenNotPaused {
        Quote storage quote = quotes[_quoteId];
        if(quote.usdcAmount == 0) {revert QuoteNotAvailable();}
        if(quote.status != Status.QuoteCreated) {revert QuoteNotCreated();}
        if(quote.user != msg.sender) {revert UnAuthorized();}
        if(quote.rampType != RampType.OnRamp) {revert InvalidRampType();}
        if(block.timestamp > quote.expireAt) {revert QuoteExpired();}
        if(bytes(_bankTxId).length == 0){ revert EmptyTxID();}

        bytes32 bankTxIdHash = keccak256(bytes(_bankTxId));

        if(usedBankTxIds[bankTxIdHash]){ revert TxIsAlreadyUsed();}

        bankProofs[_quoteId] = bankTxIdHash;
        usedBankTxIds[bankTxIdHash] = true;

        quote.status = Status.ProofSubmitted;
        quote.settlementDeadline = uint64(block.timestamp + 10 minutes);

        emit BankProofSumbitted(_quoteId, msg.sender, bankTxIdHash);
    }

    function verifyAndSettleOnRamp(uint256 _quoteId, uint256 _deadline, bytes calldata _signature ) external whenNotPaused {
        Quote storage quote = quotes[_quoteId];
        // 1. Validate quote
        if (quote.usdcAmount == 0) {revert QuoteNotAvailable(); }

        if (quote.status != Status.ProofSubmitted) { revert InvalidQuoteStatus(); }

        if (quote.rampType != RampType.OnRamp) { revert InvalidRampType(); }

        // 2. Validate signature deadline
        if (block.timestamp > _deadline) { revert SignatureExpired(); }

        if(_deadline > quote.settlementDeadline) { revert InvalidSignatureDeadline(); }

        // 3. Reconstruct the EIP-712 message
        bytes32 bankTxIdHash = bankProofs[_quoteId];

        bytes32 structHash = keccak256(abi.encode(ONRAMP_PAYMENT_TYPEHASH, _quoteId, quote.user, quote.pkrAmount, bankTxIdHash, _deadline ));

        bytes32 digest = _hashTypedDataV4(structHash);

        // 4. Recover and authenticate operator
        address signer = ECDSA.recover(digest, _signature);

        if (signer != operator) { revert UnAuthorized(); }

        // 5. Check available protocol liquidity
        if (quote.usdcAmount > totalLiquidity) { revert InsufficientLiquidity();}

        uint256 payout = quote.usdcAmount - quote.fee;
        // 6. Update state before external interaction
        quote.status = Status.Settled;
        totalLiquidity -= quote.usdcAmount;
        totalFee += quote.fee;

        // 7. Release USDC to the user
        (bool success, ) = payable(quote.user).call{value: payout}("");
        if (!success) {revert TransferFailed(); }

        emit OnRampSettled( _quoteId, quote.user, payout, signer );
    }

    function settleOffRampQuote( uint256 _quoteId, uint256 _deadline, bytes32 _bankTxIdHash, bytes calldata _signature ) external whenNotPaused {
        Quote storage quote = quotes[_quoteId];

        if(quote.usdcAmount == 0) { revert QuoteNotAvailable(); }
        if(quote.status != Status.Funded) { revert InvalidQuoteStatus(); }
        if(quote.rampType != RampType.OffRamp) { revert InvalidRampType(); }
        if(block.timestamp > quote.settlementDeadline) {revert SettlementDeadlinePassed();}
        if(_deadline > quote.settlementDeadline) { revert InvalidSignatureDeadline(); }
        if(_bankTxIdHash == bytes32(0)){ revert EmptyTxID(); }
        if (block.timestamp > _deadline) { revert SignatureExpired(); } 

        bytes32 structHash = keccak256(abi.encode(OFFRAMP_PAYMENT_TYPEHASH , _quoteId, quote.user, quote.pkrAmount, _bankTxIdHash, _deadline ));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, _signature);

        if (signer != operator) { revert UnAuthorized(); }

        totalCustodied -= quote.usdcAmount;
        totalLiquidity += quote.usdcAmount - quote.fee;
        totalFee += quote.fee;
        quote.status = Status.Settled;

        emit OffRampSettled(_quoteId, quote.user, quote.pkrAmount, signer);

    }

    function refundQuote(uint256 _quoteId) external {
        Quote storage quote = quotes[_quoteId];
        if(quote.usdcAmount < 5 ether){ revert QuoteNotAvailable(); }
        if(quote.user != msg.sender){ revert UnAuthorized(); }
        if(quote.rampType != RampType.OffRamp){revert InvalidRampType(); }
        if(quote.status != Status.Funded){ revert InvalidQuoteStatus(); }
        if(quote.settlementDeadline >= block.timestamp){ revert SettlementDeadlineNotPass();}

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

    // Owner only Functions
    function withdrawTotalFee() external onlyOwner {
        uint256 amount = totalFee;
        if(amount == 0) {revert ZeroAmount();}

        totalFee = 0;

        (bool ok,) = owner().call{value:amount}("");
        if(!ok){revert TransferFailed();}

        emit feeWithdrawn(msg.sender, amount);
    } 

    function pause() external onlyOwner { _pause(); }

    function unpause() external onlyOwner { _unpause(); }

    function changeOperator(address _newOperator) external onlyOwner {
        address oldOperator = operator;
        operator = _newOperator;
        emit operatorChanged(oldOperator, operator, msg.sender);
    }

    function changeFeeRate(uint16 _newFeeRate) external onlyOwner {
        if(_newFeeRate > 500){ revert MaxFeeRate();}
        uint16 oldFeeRate = feeRate;

        feeRate = _newFeeRate; 

        emit feeRateChanged(oldFeeRate, feeRate, msg.sender);
    }


}