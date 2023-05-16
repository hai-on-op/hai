// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {CoinJoin} from '@contracts/utils/CoinJoin.sol';
import {ISAFEEngine} from '@interfaces/ISAFEEngine.sol';
import {IToken} from '@interfaces/external/IToken.sol';
import {IAuthorizable} from '@interfaces/utils/IAuthorizable.sol';
import {IDisableable} from '@interfaces/utils/IDisableable.sol';
import {RAY} from '@libraries/Math.sol';
import {HaiTest, stdStorage, StdStorage} from '@test/utils/HaiTest.t.sol';

abstract contract Base is HaiTest {
  using stdStorage for StdStorage;

  address deployer = label('deployer');
  address authorizedAccount = label('authorizedAccount');
  address user = label('user');

  ISAFEEngine mockSafeEngine = ISAFEEngine(mockContract('SafeEngine'));
  IToken mockSystemCoin = IToken(mockContract('SystemCoin'));

  CoinJoin coinJoin;

  function setUp() public virtual {
    vm.startPrank(deployer);

    coinJoin = new CoinJoin(address(mockSafeEngine), address(mockSystemCoin));
    label(address(coinJoin), 'CoinJoin');

    coinJoin.addAuthorization(authorizedAccount);

    vm.stopPrank();
  }

  modifier authorized() {
    vm.startPrank(authorizedAccount);
    _;
  }

  function _mockContractEnabled(uint256 _contractEnabled) internal {
    stdstore.target(address(coinJoin)).sig(IDisableable.contractEnabled.selector).checked_write(_contractEnabled);
  }
}

contract Unit_CoinJoin_Constructor is Base {
  event AddAuthorization(address _account);

  function setUp() public override {
    Base.setUp();

    vm.startPrank(user);
  }

  function test_Emit_AddAuthorization() public {
    expectEmitNoIndex();
    emit AddAuthorization(user);

    coinJoin = new CoinJoin(address(mockSafeEngine), address(mockSystemCoin));
  }

  function test_Set_ContractEnabled() public {
    assertEq(coinJoin.contractEnabled(), 1);
  }

  function test_Set_SafeEngine(address _safeEngine) public {
    coinJoin = new CoinJoin(_safeEngine, address(mockSystemCoin));

    assertEq(address(coinJoin.safeEngine()), _safeEngine);
  }

  function test_Set_SystemCoin(address _systemCoin) public {
    coinJoin = new CoinJoin(address(mockSafeEngine), _systemCoin);

    assertEq(address(coinJoin.systemCoin()), _systemCoin);
  }

  function test_Set_Decimals() public {
    assertEq(coinJoin.decimals(), 18);
  }
}

contract Unit_CoinJoin_DisableContract is Base {
  event DisableContract();

  function test_Revert_Unauthorized() public {
    vm.expectRevert(IAuthorizable.Unauthorized.selector);

    coinJoin.disableContract();
  }

  function test_Revert_ContractIsDisabled() public authorized {
    _mockContractEnabled(0);

    vm.expectRevert(IDisableable.ContractIsDisabled.selector);

    coinJoin.disableContract();
  }

  function test_Emit_DisableContract() public authorized {
    expectEmitNoIndex();
    emit DisableContract();

    coinJoin.disableContract();
  }
}

contract Unit_CoinJoin_Join is Base {
  event Join(address _sender, address _account, uint256 _wad);

  function setUp() public override {
    Base.setUp();

    vm.startPrank(user);
  }

  modifier happyPath(uint256 _wad) {
    _assumeHappyPath(_wad);
    _;
  }

  function _assumeHappyPath(uint256 _wad) internal {
    vm.assume(notOverflowMul(RAY, _wad));
  }

  function test_Revert_Overflow(address _account, uint256 _wad) public {
    vm.assume(!notOverflowMul(RAY, _wad));

    vm.expectRevert();

    coinJoin.join(_account, _wad);
  }

  function test_Call_SafeEngine_TransferInternalCoins(address _account, uint256 _wad) public happyPath(_wad) {
    vm.expectCall(
      address(mockSafeEngine),
      abi.encodeCall(mockSafeEngine.transferInternalCoins, (address(coinJoin), _account, RAY * _wad))
    );

    coinJoin.join(_account, _wad);
  }

  function test_Call_SystemCoin_Burn(address _account, uint256 _wad) public happyPath(_wad) {
    vm.expectCall(address(mockSystemCoin), abi.encodeCall(mockSystemCoin.burn, (user, _wad)));

    coinJoin.join(_account, _wad);
  }

  function test_Emit_Join(address _account, uint256 _wad) public happyPath(_wad) {
    expectEmitNoIndex();
    emit Join(user, _account, _wad);

    coinJoin.join(_account, _wad);
  }
}

contract Unit_CoinJoin_Exit is Base {
  event Exit(address _sender, address _account, uint256 _wad);

  function setUp() public override {
    Base.setUp();

    vm.startPrank(user);
  }

  modifier happyPath(uint256 _wad) {
    _assumeHappyPath(_wad);
    _;
  }

  function _assumeHappyPath(uint256 _wad) internal {
    vm.assume(notOverflowMul(RAY, _wad));
  }

  function test_Revert_ContractIsDisabled(address _account, uint256 _wad) public {
    _mockContractEnabled(0);

    vm.expectRevert(IDisableable.ContractIsDisabled.selector);

    coinJoin.exit(_account, _wad);
  }

  function test_Revert_Overflow(address _account, uint256 _wad) public {
    vm.assume(!notOverflowMul(RAY, _wad));

    vm.expectRevert();

    coinJoin.exit(_account, _wad);
  }

  function test_Call_SafeEngine_TransferInternalCoins(address _account, uint256 _wad) public happyPath(_wad) {
    vm.expectCall(
      address(mockSafeEngine),
      abi.encodeCall(mockSafeEngine.transferInternalCoins, (user, address(coinJoin), RAY * _wad))
    );

    coinJoin.exit(_account, _wad);
  }

  function test_Call_SystemCoin_Mint(address _account, uint256 _wad) public happyPath(_wad) {
    vm.expectCall(address(mockSystemCoin), abi.encodeCall(mockSystemCoin.mint, (_account, _wad)));

    coinJoin.exit(_account, _wad);
  }

  function test_Emit_Exit(address _account, uint256 _wad) public happyPath(_wad) {
    expectEmitNoIndex();
    emit Exit(user, _account, _wad);

    coinJoin.exit(_account, _wad);
  }
}