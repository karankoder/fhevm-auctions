// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "./ERC20.sol";
import "fhevm/lib/TFHE.sol";
import { SepoliaZamaFHEVMConfig } from "fhevm/config/ZamaFHEVMConfig.sol";
import { SepoliaZamaGatewayConfig } from "fhevm/config/ZamaGatewayConfig.sol";
import "fhevm/gateway/GatewayCaller.sol";
import { ConfidentialERC20 } from "fhevm-contracts/contracts/token/ERC20/ConfidentialERC20.sol";

contract ConfidentialAuction is SepoliaZamaFHEVMConfig, SepoliaZamaGatewayConfig, GatewayCaller {
    // Stores the address of the contract owner
    address public contractOwner;

    // Tracks the next available auction ID
    uint256 public nextAuctionIndex = 1;

    // Constructor sets the deployer as the contract owner
    constructor() {
        contractOwner = msg.sender;
    }

    // Holds all details required to conduct an auction
    // AuctionData stores all the necessary fields for an auction:
    // 'auctionTokenAddress': The token being auctioned.
    // 'bidtokenAddress': The confidential token used to place bids.
    // 'minCount': Represents a minimally acceptable token count for the auction (1% in this case).
    // 'isOngoing': Indicates whether this auction is still open for bidding.
    struct AuctionData {
        address auctionTokenAddress;
        address bidtokenAddress;
        string auctionTitle;
        uint256 auctionId;
        address auctionOwner;
        string tokenName;
        uint64 tokenCount;
        uint64 minCount;
        uint256 startingBidTime;
        uint256 endTime;
        bool isOngoing;
    }

    // Represents each confidential bid placed in the auction
    // PrivateBid describes each bid placed in the auction:
    // 'perTokenRate': The amount the bidder is willing to pay for each unit token.
    // 'tokenAsked': The number of tokens the bidder wants to purchase at the given rate.
    struct PrivateBid {
        address bidId;
        uint256 auctionId;
        euint64 perTokenRate;
        euint64 tokenAsked;
    }

    // Facilitates sorting or grouping of bids by rate
    // BidValueSet is a helper struct used when sorting bids by their perTokenRate.
    struct BidValueSet {
        euint64 perTokenRate;
        euint64 tokenAsked;
    }

    // Mapping to store auctions initiated by each user
    mapping(address => AuctionData[]) public userHostedAuctions;
    // Mapping to store globally accessible auction details by ID
    mapping(uint256 => AuctionData) public auctionsDirectory;
    // Mapping to store all bids placed on each auction
    mapping(uint256 => PrivateBid[]) public allBids;
    // Mapping to store the final price for each auction
    mapping(uint256 => euint64) public finalPriceMap;

    // An array holding all auction records
    AuctionData[] public auctionsOverview;
    // Mapping to track bids placed by individual addresses
    mapping(address => PrivateBid[]) internal personalBids;

    // Returns the entire list of active and completed auctions
    // reviewAllAuctions shows all auctions (ongoing or ended) that have been created.
    function reviewAllAuctions() public view returns (AuctionData[] memory) {
        return auctionsOverview;
    }

    // Initiates a new auction, sets parameters, and transfers tokens to the contract
    // beginAuction initializes a new auction by transferring ownership of the specified number of tokens.
    // '_propertyToken' is the token contract address for items to be auctioned.
    // '_currencyToken' is the confidential token used for bidding.
    function beginAuction(
        address _itemToken,
        address _biddingToken,
        string calldata _auctionDescription,
        uint64 _totalUnits,
        uint256 _beginDelay,
        uint256 _finishingTime
    ) public {
        AuctionData memory newAuction = AuctionData({
            auctionTokenAddress: _itemToken,
            bidtokenAddress: _biddingToken,
            auctionTitle: _auctionDescription,
            auctionOwner: msg.sender,
            auctionId: nextAuctionIndex,
            tokenName: "auctionToken",
            tokenCount: _totalUnits,
            startingBidTime: block.timestamp + _beginDelay,
            minCount: (_totalUnits * 1) / 100,
            endTime: block.timestamp + _finishingTime,
            isOngoing: true
        });

        userHostedAuctions[msg.sender].push(newAuction);
        auctionsDirectory[nextAuctionIndex] = newAuction;
        auctionsOverview.push(newAuction);

        // Transfer the auction funds
        euint64 encryptedAmount = TFHE.asEuint64(_totalUnits);
        TFHE.allowThis(encryptedAmount);
        TFHE.allowTransient(encryptedAmount, _itemToken);
        require(ConfidentialERC20(_itemToken).transferFrom(msg.sender, address(this), encryptedAmount));
        nextAuctionIndex++;
    }

    // Allows a user to bid confidentially on an auction
    // pushProtectedBid allows a user to bid on an auction using encrypted inputs.
    // It updates internal tracking (myActiveBids and auctionOfferings) and transfers the bid amount.
    // If the bidder already has an active bid, the transaction reverts.
    function pushProtectedBid(
        uint256 _targetAuction,
        einput _encryptedRate,
        bytes calldata _proofRate,
        einput _encryptedUnits,
        bytes calldata _proofUnits
    ) public {
        uint256 localAuctionId = _targetAuction;
        euint64 rateEach = TFHE.asEuint64(_encryptedRate, _proofRate);
        euint64 requestedUnits = TFHE.asEuint64(_encryptedUnits, _proofUnits);
        address bidderAddress = msg.sender;

        TFHE.allowThis(rateEach);
        TFHE.allowThis(requestedUnits);
        PrivateBid memory freshBid = PrivateBid({
            auctionId: localAuctionId,
            bidId: bidderAddress,
            perTokenRate: rateEach,
            tokenAsked: requestedUnits
        });

        TFHE.allowThis(freshBid.perTokenRate);
        TFHE.allowThis(freshBid.tokenAsked);

        for (uint i = 0; i < personalBids[bidderAddress].length; i++) {
            if (personalBids[bidderAddress][i].auctionId == localAuctionId) {
                revert("Bid already exists for this auction");
            }
        }
        personalBids[bidderAddress].push(freshBid);

        TFHE.allowThis(personalBids[bidderAddress][personalBids[bidderAddress].length - 1].perTokenRate);
        TFHE.allowThis(personalBids[bidderAddress][personalBids[bidderAddress].length - 1].tokenAsked);

        allBids[localAuctionId].push(freshBid);
        TFHE.allowThis(allBids[localAuctionId][allBids[localAuctionId].length - 1].perTokenRate);
        TFHE.allowThis(allBids[localAuctionId][allBids[localAuctionId].length - 1].tokenAsked);

        euint64 finalAmount = TFHE.mul(requestedUnits, rateEach);
        TFHE.allowThis(finalAmount);
        TFHE.allowTransient(finalAmount, auctionsDirectory[localAuctionId].bidtokenAddress);
        ConfidentialERC20(auctionsDirectory[localAuctionId].bidtokenAddress).transferFrom(msg.sender, address(this), finalAmount);
    }

    // Sorts bids in descending order by token rate for final price calculation
    // orderBidsDescending sorts the bids by their perTokenRate in descending order
    // to ensure we can accurately determine the best (highest) bids first.
    function orderBidsDescending(uint256 _identifier) private returns (BidValueSet[] memory) {
        uint256 auctionId = _identifier;
        require(auctionsDirectory[auctionId].isOngoing == true, "Auction not active");
        PrivateBid[] memory existingBids = allBids[_identifier];
        BidValueSet[] memory sortedBids = new BidValueSet[](existingBids.length);
        for (uint64 i = 0; i < existingBids.length; i++) {
            TFHE.allowThis(existingBids[i].perTokenRate);
            TFHE.allowThis(existingBids[i].tokenAsked);
            sortedBids[i].perTokenRate = existingBids[i].perTokenRate;
            sortedBids[i].tokenAsked = existingBids[i].tokenAsked;
            TFHE.allowThis(sortedBids[i].perTokenRate);
            TFHE.allowThis(sortedBids[i].tokenAsked);
        }

        for (uint i = 0; i < existingBids.length; i++) {
            for (uint j = 0; j < existingBids.length - i - 1; j++) {
                ebool isTrue = TFHE.lt(sortedBids[j].perTokenRate, sortedBids[j + 1].perTokenRate);
                TFHE.allowThis(isTrue);
                BidValueSet memory tempSet = sortedBids[j];
                TFHE.allowThis(tempSet.perTokenRate);
                TFHE.allowThis(tempSet.tokenAsked);

                sortedBids[j].perTokenRate = TFHE.select(
                    isTrue,
                    sortedBids[j + 1].perTokenRate,
                    sortedBids[j].perTokenRate
                );
                sortedBids[j].tokenAsked = TFHE.select(
                    isTrue,
                    sortedBids[j + 1].tokenAsked,
                    sortedBids[j].tokenAsked
                );
                TFHE.allowThis(sortedBids[j].perTokenRate);
                TFHE.allowThis(sortedBids[j].tokenAsked);
            }
        }
        return sortedBids;
    }

    // Calculates the closing price of the auction based on sorted bids
    // calculateClosingPrice computes the auction’s final price based on the highest valid bids.
    // It factors in the total token supply ('totalTokens') and tracks how many remain ('tempTotalTokens').
    function calculateClosingPrice(uint256 _auctionNum) public returns (euint64) {
        uint256 auctionId = _auctionNum;
        PrivateBid[] memory existingBids = allBids[_auctionNum];
        BidValueSet[] memory sortedBids = orderBidsDescending(_auctionNum);
        euint64 totalInventory = TFHE.asEuint64(auctionsDirectory[_auctionNum].tokenCount);
        TFHE.allowThis(totalInventory);

        euint64 currentInventory = totalInventory;
        TFHE.allowThis(currentInventory);

        euint64 determinedRate = TFHE.asEuint64(0);
        TFHE.allowThis(determinedRate);

        for (uint256 i = 0; i < existingBids.length; i++) {
            ebool isTrue = TFHE.gt(currentInventory, 0);
            TFHE.allowThis(isTrue);
            euint64 countNow = TFHE.select(isTrue, sortedBids[i].tokenAsked, TFHE.asEuint64(0));
            TFHE.allowThis(countNow);

            countNow = TFHE.select(
                isTrue,
                TFHE.select(TFHE.gt(countNow, currentInventory), currentInventory, countNow),
                countNow
            );
            TFHE.allowThis(countNow);
            currentInventory = TFHE.select(isTrue, TFHE.sub(currentInventory, countNow), currentInventory);
            TFHE.allowThis(currentInventory);
            determinedRate = TFHE.select(isTrue, sortedBids[i].perTokenRate, determinedRate);
            TFHE.allowThis(determinedRate);
        }
        finalPriceMap[_auctionNum] = determinedRate;
        TFHE.allowThis(finalPriceMap[_auctionNum]);
        TFHE.allow(finalPriceMap[_auctionNum], msg.sender);
        return determinedRate;
    }

    // Provides the final price of the specified auction
    // readAuctionCost retrieves the final price for a specific auction.
    // This price gets computed during calculateClosingPrice().
    function readAuctionCost(uint256 _eventId) public view returns (euint64) {
        return finalPriceMap[_eventId];
    }

    // Concludes the auction, distributes tokens to winners, and refunds any unused bids
    // completeAuction concludes the auction, determines winning bids, and transfers tokens
    // (both for the item being auctioned and the bid amounts). Any leftover tokens are returned to their owners.
    function completeAuction(uint256 _eventId) public {
        uint256 auctionId = _eventId;
        PrivateBid[] memory concludedBids = allBids[_eventId];
        euint64 totalInventory = TFHE.asEuint64(auctionsDirectory[_eventId].tokenCount);
        TFHE.allowThis(totalInventory);
        euint64 leftoverUnits = totalInventory;
        euint64 concludedPrice = finalPriceMap[_eventId];

        leftoverUnits = totalInventory;
        TFHE.allowThis(leftoverUnits);
        
        for (uint256 i = 0; i < concludedBids.length; i++) {
            euint64 neededUnits = concludedBids[i].tokenAsked;
            TFHE.allowThis(neededUnits);

            ebool isgreater = TFHE.gt(neededUnits, leftoverUnits);
            TFHE.allowThis(isgreater);
            neededUnits = TFHE.select(isgreater, leftoverUnits, neededUnits);
            TFHE.allowThis(neededUnits);

            ebool isCondition = TFHE.gt(leftoverUnits, 0);
            TFHE.allowThis(isCondition);
            isCondition = TFHE.and(isCondition, TFHE.ge(concludedBids[i].perTokenRate, concludedPrice));
            TFHE.allowThis(isCondition);
            leftoverUnits = TFHE.select(isCondition, TFHE.sub(leftoverUnits, neededUnits), leftoverUnits);
            TFHE.allowThis(leftoverUnits);
            TFHE.allowTransient(neededUnits, auctionsDirectory[auctionId].auctionTokenAddress);
            ConfidentialERC20(auctionsDirectory[auctionId].auctionTokenAddress).transfer(concludedBids[i].bidId, neededUnits);

            euint64 partialBid = TFHE.mul(concludedBids[i].tokenAsked, concludedBids[i].perTokenRate);
            TFHE.allowThis(partialBid);
            euint64 finalPayment = TFHE.mul(neededUnits, concludedPrice);
            TFHE.allowThis(finalPayment);
            euint64 differenceAmount = TFHE.sub(partialBid, finalPayment);
            TFHE.allowThis(differenceAmount);

            TFHE.allowTransient(differenceAmount, auctionsDirectory[auctionId].bidtokenAddress);
            ConfidentialERC20(auctionsDirectory[auctionId].bidtokenAddress).transfer(concludedBids[i].bidId, differenceAmount);
        }
        TFHE.allowThis(totalInventory);
        TFHE.allowThis(leftoverUnits);
        euint64 soldUnits = TFHE.sub(totalInventory, leftoverUnits);
        TFHE.allowThis(soldUnits);
        TFHE.allowThis(concludedPrice);
        euint64 finalTransfer = TFHE.mul(soldUnits, concludedPrice);
        TFHE.allowThis(finalTransfer);
        TFHE.allowTransient(finalTransfer, auctionsDirectory[auctionId].bidtokenAddress);
        ConfidentialERC20(auctionsDirectory[auctionId].bidtokenAddress).transfer(
            auctionsDirectory[auctionId].auctionOwner,
            finalTransfer
        );

        TFHE.allowTransient(leftoverUnits, auctionsDirectory[auctionId].auctionTokenAddress);
        ConfidentialERC20(auctionsDirectory[auctionId].auctionTokenAddress).transfer(
            auctionsDirectory[auctionId].auctionOwner,
            leftoverUnits
        );
        auctionsDirectory[auctionId].isOngoing = false;
    }
}
