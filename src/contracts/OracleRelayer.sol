// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {ISAFEEngine} from '@interfaces/ISAFEEngine.sol';
import {IBaseOracle} from '@interfaces/oracles/IBaseOracle.sol';
import {IDelayedOracle} from '@interfaces/oracles/IDelayedOracle.sol';
import {IOracleRelayer} from '@interfaces/IOracleRelayer.sol';

import {Authorizable} from '@contracts/utils/Authorizable.sol';
import {Modifiable} from '@contracts/utils/Modifiable.sol';
import {Disableable} from '@contracts/utils/Disableable.sol';

import {Encoding} from '@libraries/Encoding.sol';
import {Assertions} from '@libraries/Assertions.sol';
import {Math, RAY, WAD} from '@libraries/Math.sol';

contract OracleRelayer is Authorizable, Modifiable, Disableable, IOracleRelayer {
  using Encoding for bytes;
  using Math for uint256;
  using Assertions for uint256;
  using Assertions for address;

  // --- Registry ---
  ISAFEEngine public safeEngine;
  IBaseOracle public systemCoinOracle;

  // --- Params ---
  // solhint-disable-next-line private-vars-leading-underscore
  OracleRelayerParams public _params;
  // solhint-disable-next-line private-vars-leading-underscore
  mapping(bytes32 => OracleRelayerCollateralParams) public _cParams;

  function params() external view override returns (OracleRelayerParams memory _oracleRelayerParams) {
    return _params;
  }

  function cParams(bytes32 _cType) external view returns (OracleRelayerCollateralParams memory _oracleRelayerCParams) {
    return _cParams[_cType];
  }

  // Virtual redemption price (not the most updated value)
  uint256 internal _redemptionPrice; // [ray]
  // The force that changes the system users' incentives by changing the redemption price
  uint256 public redemptionRate; // [ray]
  // Last time when the redemption price was changed
  uint256 public redemptionPriceUpdateTime; // [unix epoch time]

  // --- Init ---
  constructor(
    address _safeEngine,
    IBaseOracle _systemCoinOracle,
    OracleRelayerParams memory _oracleRelayerParams
  ) Authorizable(msg.sender) validParams {
    safeEngine = ISAFEEngine(_safeEngine.assertNonNull());
    systemCoinOracle = _systemCoinOracle;
    _redemptionPrice = RAY;
    redemptionRate = RAY;
    redemptionPriceUpdateTime = block.timestamp;
    _params = _oracleRelayerParams;
  }

  /**
   * @notice Fetch the market price from the system coin oracle
   */
  function marketPrice() external view returns (uint256 _marketPrice) {
    (uint256 _priceFeedValue, bool _hasValidValue) = systemCoinOracle.getResultWithValidity();
    if (_hasValidValue) return _priceFeedValue;
  }

  // --- Redemption Price Update ---
  /**
   * @notice Update the redemption price using the current redemption rate
   */
  function _updateRedemptionPrice() internal virtual returns (uint256 _updatedPrice) {
    // Update redemption price
    _updatedPrice = redemptionRate.rpow(block.timestamp - redemptionPriceUpdateTime).rmul(_redemptionPrice);
    if (_updatedPrice == 0) _updatedPrice = 1;
    _redemptionPrice = _updatedPrice;
    redemptionPriceUpdateTime = block.timestamp;
    emit UpdateRedemptionPrice(_updatedPrice);
  }

  /**
   * @notice Fetch the latest redemption price by first updating it
   */
  function redemptionPrice() external returns (uint256 _updatedPrice) {
    return _getRedemptionPrice();
  }

  function _getRedemptionPrice() internal virtual returns (uint256 _updatedPrice) {
    if (block.timestamp > redemptionPriceUpdateTime) return _updateRedemptionPrice();
    return _redemptionPrice;
  }

  // --- Update value ---
  /**
   * @notice Update the collateral price inside the system (inside SAFEEngine)
   * @param  _cType The collateral we want to update prices (safety and liquidation prices) for
   */
  function updateCollateralPrice(bytes32 _cType) external whenEnabled {
    (uint256 _priceFeedValue, bool _hasValidValue) = _cParams[_cType].oracle.getResultWithValidity();
    uint256 _updatedRedemptionPrice = _getRedemptionPrice();

    uint256 _safetyPrice = _hasValidValue
      ? (uint256(_priceFeedValue) * uint256(10 ** 9)).rdiv(_updatedRedemptionPrice).rdiv(_cParams[_cType].safetyCRatio)
      : 0;
    uint256 _liquidationPrice = _hasValidValue
      ? (uint256(_priceFeedValue) * uint256(10 ** 9)).rdiv(_updatedRedemptionPrice).rdiv(
        _cParams[_cType].liquidationCRatio
      )
      : 0;

    safeEngine.updateCollateralPrice(_cType, _safetyPrice, _liquidationPrice);
    emit UpdateCollateralPrice(_cType, _priceFeedValue, _safetyPrice, _liquidationPrice);
  }

  function updateRedemptionRate(uint256 _redemptionRate) external isAuthorized whenEnabled {
    if (block.timestamp != redemptionPriceUpdateTime) revert OracleRelayer_RedemptionPriceNotUpdated();

    if (_redemptionRate > _params.redemptionRateUpperBound) {
      _redemptionRate = _params.redemptionRateUpperBound;
    } else if (_redemptionRate < _params.redemptionRateLowerBound) {
      _redemptionRate = _params.redemptionRateLowerBound;
    }
    redemptionRate = _redemptionRate;
  }

  function initializeCollateralType(
    bytes32 _cType,
    OracleRelayerCollateralParams memory _collateralParams
  ) external isAuthorized validCParams(_cType) {
    if (address(_cParams[_cType].oracle) != address(0)) revert OracleRelayer_CollateralTypeAlreadyInitialized();
    _validateDelayedOracle(address(_collateralParams.oracle));
    _cParams[_cType] = _collateralParams;
  }

  // --- Shutdown ---

  /**
   * @notice Disable this contract (normally called by GlobalSettlement)
   */
  function _onContractDisable() internal override {
    redemptionRate = RAY;
  }

  // --- Administration ---

  function _modifyParameters(bytes32 _param, bytes memory _data) internal override whenEnabled {
    uint256 _uint256 = _data.toUint256();

    if (_param == 'systemCoinOracle') systemCoinOracle = IBaseOracle(_data.toAddress().assertNonNull());
    else if (_param == 'redemptionRateUpperBound') _params.redemptionRateUpperBound = _uint256;
    else if (_param == 'redemptionRateLowerBound') _params.redemptionRateLowerBound = _uint256;
    else revert UnrecognizedParam();
  }

  function _modifyParameters(bytes32 _cType, bytes32 _param, bytes memory _data) internal override whenEnabled {
    uint256 _uint256 = _data.toUint256();
    OracleRelayerCollateralParams storage __cParams = _cParams[_cType];

    if (_param == 'safetyCRatio') __cParams.safetyCRatio = _uint256;
    else if (_param == 'liquidationCRatio') __cParams.liquidationCRatio = _uint256;
    else if (_param == 'oracle') __cParams.oracle = _validateDelayedOracle(_data.toAddress());
    else revert UnrecognizedParam();
  }

  function _validateDelayedOracle(address _oracle) internal view returns (IDelayedOracle _delayedOracle) {
    // Checks if the delayed oracle priceSource is implemented
    _delayedOracle = IDelayedOracle(_oracle.assertNonNull());
    _delayedOracle.priceSource();
  }

  function _validateParameters() internal view override {
    _params.redemptionRateUpperBound.assertGt(RAY);
    _params.redemptionRateLowerBound.assertGt(0).assertLt(RAY);
    address(systemCoinOracle).assertNonNull();
  }

  function _validateCParameters(bytes32 _cType) internal view override {
    OracleRelayerCollateralParams memory _collateralParams = _cParams[_cType];
    _collateralParams.safetyCRatio.assertGtEq(_collateralParams.liquidationCRatio);
    _collateralParams.liquidationCRatio.assertGtEq(RAY);
    address(_collateralParams.oracle).assertNonNull();
  }
}
