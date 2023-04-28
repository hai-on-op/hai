// SPDX-License-Identifier: GPL-3.0
/// LiquidationEngine.sol

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

import {ICollateralAuctionHouse as CollateralAuctionHouseLike} from '@interfaces/ICollateralAuctionHouse.sol';
import {ISAFESaviour as SAFESaviourLike} from '@interfaces/external/ISAFESaviour.sol';
import {ISAFEEngine as SAFEEngineLike} from '@interfaces/ISAFEEngine.sol';
import {IAccountingEngine as AccountingEngineLike} from '@interfaces/IAccountingEngine.sol';
import {ILiquidationEngine, GLOBAL_PARAM} from '@interfaces/ILiquidationEngine.sol';

import {Authorizable} from '@contracts/utils/Authorizable.sol';
import {Disableable} from '@contracts/utils/Disableable.sol';
import {Math, RAY, WAD, MAX_RAD} from '@libraries/Math.sol';
import {Encoding} from '@libraries/Encoding.sol';

contract LiquidationEngine is Authorizable, Disableable, ILiquidationEngine {
  using Encoding for bytes;
  using Math for uint256;

  // --- SAFE Saviours ---
  // Contracts that can save SAFEs from liquidation
  mapping(address => uint256) public safeSaviours;

  // Saviour contract chosen for each SAFE by its creator
  mapping(bytes32 => mapping(address => address)) public chosenSAFESaviour;
  // Mutex used to block against re-entrancy when 'liquidateSAFE' passes execution to a saviour
  mapping(bytes32 => mapping(address => uint8)) public mutex;

  // Current amount of system coins out for liquidation
  uint256 public currentOnAuctionSystemCoins; // [rad]

  SAFEEngineLike public safeEngine;

  LiquidationEngineParams public params;
  mapping(bytes32 _cType => LiquidationEngineCollateralParams) public cParams;

  // --- Init ---
  constructor(address _safeEngine) Authorizable(msg.sender) {
    safeEngine = SAFEEngineLike(_safeEngine);

    params.onAuctionSystemCoinLimit = type(uint256).max;
    emit ModifyParameters('onAuctionSystemCoinLimit', GLOBAL_PARAM, abi.encode(type(uint256).max));
  }

  /**
   * @notice Authed function to add contracts that can save SAFEs from liquidation
   * @param  _saviour SAFE saviour contract to be whitelisted
   */
  function connectSAFESaviour(address _saviour) external isAuthorized {
    (bool _ok, uint256 _collateralAdded, uint256 _liquidatorReward) =
      SAFESaviourLike(_saviour).saveSAFE(address(this), '', address(0));
    require(_ok, 'LiquidationEngine/saviour-not-ok');
    require(
      (_collateralAdded == type(uint256).max) && (_liquidatorReward == type(uint256).max),
      'LiquidationEngine/invalid-amounts'
    );
    safeSaviours[_saviour] = 1;
    emit ConnectSAFESaviour(_saviour);
  }

  /**
   * @notice Governance used function to remove contracts that can save SAFEs from liquidation
   * @param  _saviour SAFE saviour contract to be removed
   */
  function disconnectSAFESaviour(address _saviour) external isAuthorized {
    safeSaviours[_saviour] = 0;
    emit DisconnectSAFESaviour(_saviour);
  }

  /**
   * @notice Disable this contract (normally called by GlobalSettlement)
   */
  function disableContract() external isAuthorized whenEnabled {
    _disableContract();
  }

  // --- SAFE Liquidation ---
  /**
   * @notice Choose a saviour contract for your SAFE
   * @param  _cType The SAFE's collateral type
   * @param  _safe The SAFE's address
   * @param  _saviour The chosen saviour
   */
  function protectSAFE(bytes32 _cType, address _safe, address _saviour) external {
    require(safeEngine.canModifySAFE(_safe, msg.sender), 'LiquidationEngine/cannot-modify-safe');
    require(_saviour == address(0) || safeSaviours[_saviour] == 1, 'LiquidationEngine/saviour-not-authorized');
    chosenSAFESaviour[_cType][_safe] = _saviour;
    emit ProtectSAFE(_cType, _safe, _saviour);
  }

  /**
   * @notice Liquidate a SAFE
   * @param  _cType The SAFE's collateral type
   * @param  _safe The SAFE's address
   */
  function liquidateSAFE(bytes32 _cType, address _safe) external whenEnabled returns (uint256 _auctionId) {
    require(mutex[_cType][_safe] == 0, 'LiquidationEngine/non-null-mutex');
    mutex[_cType][_safe] = 1;

    (, uint256 _accumulatedRate) = safeEngine.cData(_cType);
    (,, uint256 _debtFloor, uint256 _liquidationPrice) = safeEngine.cParams(_cType);
    (uint256 _safeCollateral, uint256 _safeDebt) = safeEngine.safes(_cType, _safe);

    require(
      (_liquidationPrice > 0) && (_safeCollateral * _liquidationPrice < _safeDebt * _accumulatedRate),
      'LiquidationEngine/safe-not-unsafe'
    );
    require(
      currentOnAuctionSystemCoins < params.onAuctionSystemCoinLimit
        && params.onAuctionSystemCoinLimit - currentOnAuctionSystemCoins >= _debtFloor,
      'LiquidationEngine/liquidation-limit-hit'
    );

    if (chosenSAFESaviour[_cType][_safe] != address(0) && safeSaviours[chosenSAFESaviour[_cType][_safe]] == 1) {
      try SAFESaviourLike(chosenSAFESaviour[_cType][_safe]).saveSAFE(msg.sender, _cType, _safe) returns (
        bool _ok, uint256 _collateralAddedOrDebtRepaid, uint256
      ) {
        if (_ok && _collateralAddedOrDebtRepaid > 0) {
          emit SaveSAFE(_cType, _safe, _collateralAddedOrDebtRepaid);
        }
      } catch (bytes memory _revertReason) {
        emit FailedSAFESave(_revertReason);
      }
    }

    // Checks that the saviour didn't take collateral or add more debt to the SAFE
    {
      (uint256 _newSafeCollateral, uint256 _newSafeDebt) = safeEngine.safes(_cType, _safe);
      require(
        _newSafeCollateral >= _safeCollateral && _newSafeDebt <= _safeDebt,
        'LiquidationEngine/invalid-safe-saviour-operation'
      );
    }

    // NOTE: can accumulatedRate change within this call?
    (, _accumulatedRate) = safeEngine.cData(_cType);
    (,,, _liquidationPrice) = safeEngine.cParams(_cType);
    (_safeCollateral, _safeDebt) = safeEngine.safes(_cType, _safe);

    if ((_liquidationPrice > 0) && (_safeCollateral * _liquidationPrice < _safeDebt * _accumulatedRate)) {
      LiquidationEngineCollateralParams memory _cParams = cParams[_cType];

      uint256 _limitAdjustedDebt = Math.min(
        _safeDebt,
        Math.min(_cParams.liquidationQuantity, params.onAuctionSystemCoinLimit - currentOnAuctionSystemCoins) * WAD
          / _accumulatedRate / _cParams.liquidationPenalty
      );

      require(_limitAdjustedDebt > 0, 'LiquidationEngine/null-auction');
      require(
        (_limitAdjustedDebt == _safeDebt) || ((_safeDebt - _limitAdjustedDebt) * _accumulatedRate >= _debtFloor),
        'LiquidationEngine/dusty-safe'
      );

      uint256 _collateralToSell = Math.min(_safeCollateral, _safeCollateral * _limitAdjustedDebt / _safeDebt);

      require(_collateralToSell > 0, 'LiquidationEngine/null-collateral-to-sell');
      require(
        _collateralToSell <= 2 ** 255 && _limitAdjustedDebt <= 2 ** 255, 'LiquidationEngine/collateral-or-debt-overflow'
      );

      safeEngine.confiscateSAFECollateralAndDebt(
        _cType,
        _safe,
        address(this),
        address(params.accountingEngine),
        -int256(_collateralToSell),
        -int256(_limitAdjustedDebt)
      );
      params.accountingEngine.pushDebtToQueue(_limitAdjustedDebt * _accumulatedRate);

      {
        // This calcuation will overflow if multiply(limitAdjustedDebt, accumulatedRate) exceeds ~10^14,
        // i.e. the maximum amountToRaise is roughly 100 trillion system coins.
        uint256 _amountToRaise = _limitAdjustedDebt * _accumulatedRate * _cParams.liquidationPenalty / WAD;
        currentOnAuctionSystemCoins += _amountToRaise;

        _auctionId = CollateralAuctionHouseLike(_cParams.collateralAuctionHouse).startAuction({
          _forgoneCollateralReceiver: _safe,
          _initialBidder: address(params.accountingEngine),
          _amountToRaise: _amountToRaise,
          _collateralToSell: _collateralToSell,
          _initialBid: 0
        });

        emit UpdateCurrentOnAuctionSystemCoins(currentOnAuctionSystemCoins);
      }

      emit Liquidate(
        _cType,
        _safe,
        _collateralToSell,
        _limitAdjustedDebt,
        _limitAdjustedDebt * _accumulatedRate,
        _cParams.collateralAuctionHouse,
        _auctionId
      );
    }

    mutex[_cType][_safe] = 0;
  }

  /**
   * @notice Remove debt that was being auctioned
   * @param  _rad The amount of debt to withdraw from currentOnAuctionSystemCoins
   */
  function removeCoinsFromAuction(uint256 _rad) public isAuthorized {
    currentOnAuctionSystemCoins -= _rad;
    emit UpdateCurrentOnAuctionSystemCoins(currentOnAuctionSystemCoins);
  }

  // --- Getters ---
  /**
   * @notice Get the amount of debt that can currently be covered by a collateral auction for a specific safe
   * @param  _cType The collateral type stored in the SAFE
   * @param  _safe The SAFE's address/handler
   */
  function getLimitAdjustedDebtToCover(bytes32 _cType, address _safe) external view returns (uint256) {
    (, uint256 _accumulatedRate) = safeEngine.cData(_cType);
    (, uint256 _safeDebt) = safeEngine.safes(_cType, _safe);
    LiquidationEngineCollateralParams memory _cParams = cParams[_cType];

    return Math.min(
      _safeDebt,
      Math.min(_cParams.liquidationQuantity, params.onAuctionSystemCoinLimit - currentOnAuctionSystemCoins) * WAD
        / _accumulatedRate / _cParams.liquidationPenalty
    );
  }

  // --- Administration ---
  /**
   * @notice Modify parameters
   * @param  _param The name of the parameter modified
   * @param  _data Value for the new parameter
   */
  function modifyParameters(bytes32 _param, bytes memory _data) external isAuthorized {
    if (_param == 'onAuctionSystemCoinLimit') params.onAuctionSystemCoinLimit = _data.toUint256();
    else if (_param == 'accountingEngine') params.accountingEngine = abi.decode(_data, (AccountingEngineLike));
    else revert UnrecognizedParam();
    emit ModifyParameters(_param, GLOBAL_PARAM, _data);
  }

  /**
   * @notice Modify liquidation params
   * @param  _cType The collateral type we change parameters for
   * @param  _param The name of the parameter modified
   * @param  _data New value for the parameter
   */
  function modifyParameters(bytes32 _cType, bytes32 _param, bytes memory _data) external isAuthorized {
    uint256 _uint256 = _data.toUint256();

    if (_param == 'liquidationPenalty') cParams[_cType].liquidationPenalty = _uint256;
    // NOTE: *= 1 avoids overflow
    else if (_param == 'liquidationQuantity') cParams[_cType].liquidationQuantity = _uint256.rmul(RAY);
    else if (_param == 'collateralAuctionHouse') _setCollateralAuctionHouse(_cType, _data.toAddress());
    else revert UnrecognizedParam();

    emit ModifyParameters(_param, _cType, _data);
  }

  function _setCollateralAuctionHouse(bytes32 _cType, address _newCollateralAuctionHouse) internal {
    safeEngine.denySAFEModification(cParams[_cType].collateralAuctionHouse);
    cParams[_cType].collateralAuctionHouse = _newCollateralAuctionHouse;
    safeEngine.approveSAFEModification(_newCollateralAuctionHouse);
  }
}
