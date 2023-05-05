// SPDX-License-Identifier: GPL-3.0
/// SurplusAuctionHouse.sol

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.8.19;

import {
  IPostSettlementSurplusAuctionHouse,
  SAFEEngineLike,
  TokenLike,
  GLOBAL_PARAM
} from '@interfaces/settlement/IPostSettlementSurplusAuctionHouse.sol';

import {Authorizable} from '@contracts/utils/Authorizable.sol';

import {WAD} from '@libraries/Math.sol';
import {Encoding} from '@libraries/Encoding.sol';

contract PostSettlementSurplusAuctionHouse is IPostSettlementSurplusAuctionHouse, Authorizable {
  using Encoding for bytes;

  // --- Data ---
  // Bid data for each separate auction
  mapping(uint256 => Bid) public bids;

  // SAFE database
  SAFEEngineLike public safeEngine;
  // Protocol token address
  TokenLike public protocolToken;

  // Number of auctions started up until now
  uint256 public auctionsStarted;

  // --- Params ---
  PostSettlementSAHParams _params;

  function params() external view returns (PostSettlementSAHParams memory) {
    return _params;
  }

  bytes32 public constant AUCTION_HOUSE_TYPE = bytes32('SURPLUS');
  bytes32 public constant SURPLUS_AUCTION_TYPE = bytes32('POST-SETTLEMENT');

  // --- Init ---
  constructor(address _safeEngine, address _protocolToken) Authorizable(msg.sender) {
    safeEngine = SAFEEngineLike(_safeEngine);
    protocolToken = TokenLike(_protocolToken);

    _params = PostSettlementSAHParams({bidIncrease: 1.05e18, bidDuration: 3 hours, totalAuctionLength: 2 days});
  }

  // --- Admin ---
  /**
   * @notice Modify uint256 parameters
   * @param _parameter The name of the parameter modified
   * @param _data New value for the parameter
   */
  function modifyParameters(bytes32 _parameter, bytes memory _data) external isAuthorized {
    uint256 _uint256 = _data.toUint256();

    if (_parameter == 'bidIncrease') _params.bidIncrease = _uint256;
    else if (_parameter == 'bidDuration') _params.bidDuration = uint48(_uint256);
    else if (_parameter == 'totalAuctionLength') _params.totalAuctionLength = uint48(_uint256);
    else revert UnrecognizedParam();
    emit ModifyParameters(_parameter, GLOBAL_PARAM, _data);
  }

  // --- Auction ---
  /**
   * @notice Start a new surplus auction
   * @param _amountToSell Total amount of system coins to sell (wad)
   * @param _initialBid Initial protocol token bid (rad)
   */
  function startAuction(uint256 _amountToSell, uint256 _initialBid) external isAuthorized returns (uint256 _id) {
    _id = ++auctionsStarted;

    bids[_id].bidAmount = _initialBid;
    bids[_id].amountToSell = _amountToSell;
    bids[_id].highBidder = msg.sender;
    bids[_id].auctionDeadline = uint48(block.timestamp) + _params.totalAuctionLength;

    safeEngine.transferInternalCoins(msg.sender, address(this), _amountToSell);

    emit StartAuction(_id, auctionsStarted, _amountToSell, _initialBid, bids[_id].auctionDeadline);
  }

  /**
   * @notice Restart an auction if no bids were submitted for it
   * @param _id ID of the auction to restart
   */
  function restartAuction(uint256 _id) external {
    require(bids[_id].auctionDeadline < block.timestamp, 'PostSettlementSurplusAuctionHouse/not-finished');
    require(bids[_id].bidExpiry == 0, 'PostSettlementSurplusAuctionHouse/bid-already-placed');
    bids[_id].auctionDeadline = uint48(block.timestamp) + _params.totalAuctionLength;
    emit RestartAuction(_id, bids[_id].auctionDeadline);
  }

  /**
   * @notice Submit a higher protocol token bid for the same amount of system coins
   * @param _id ID of the auction you want to submit the bid for
   * @param _amountToBuy Amount of system coins to buy (wad)
   * @param _bid New bid submitted (rad)
   */
  function increaseBidSize(uint256 _id, uint256 _amountToBuy, uint256 _bid) external {
    require(bids[_id].highBidder != address(0), 'PostSettlementSurplusAuctionHouse/high-bidder-not-set');
    require(
      bids[_id].bidExpiry > block.timestamp || bids[_id].bidExpiry == 0,
      'PostSettlementSurplusAuctionHouse/bid-already-expired'
    );
    require(bids[_id].auctionDeadline > block.timestamp, 'PostSettlementSurplusAuctionHouse/auction-already-expired');

    require(_amountToBuy == bids[_id].amountToSell, 'PostSettlementSurplusAuctionHouse/amounts-not-matching');
    require(_bid > bids[_id].bidAmount, 'PostSettlementSurplusAuctionHouse/bid-not-higher');
    require(
      _bid * WAD >= _params.bidIncrease * bids[_id].bidAmount, 'PostSettlementSurplusAuctionHouse/insufficient-increase'
    );

    if (msg.sender != bids[_id].highBidder) {
      protocolToken.move(msg.sender, bids[_id].highBidder, bids[_id].bidAmount);
      bids[_id].highBidder = msg.sender;
    }
    protocolToken.move(msg.sender, address(this), _bid - bids[_id].bidAmount);

    bids[_id].bidAmount = _bid;
    bids[_id].bidExpiry = uint48(block.timestamp) + _params.bidDuration;

    emit IncreaseBidSize(_id, msg.sender, _amountToBuy, _bid, bids[_id].bidExpiry);
  }

  /**
   * @notice Settle/finish an auction
   * @param _id ID of the auction to settle
   */
  function settleAuction(uint256 _id) external {
    require(
      bids[_id].bidExpiry != 0 && (bids[_id].bidExpiry < block.timestamp || bids[_id].auctionDeadline < block.timestamp),
      'PostSettlementSurplusAuctionHouse/not-finished'
    );
    safeEngine.transferInternalCoins(address(this), bids[_id].highBidder, bids[_id].amountToSell);
    protocolToken.burn(address(this), bids[_id].bidAmount);
    delete bids[_id];
    emit SettleAuction(_id);
  }
}