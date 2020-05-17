/// StabilityFeeTreasury.t.sol

// Copyright (C) 2015-2020  DappHub, LLC
// Copyright (C) 2020       Stefan C. Ionescu <stefanionescu@protonmail.com>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.5.15;

import "ds-test/test.sol";

import {Coin} from '../Coin.sol';
import {CDPEngine} from '../CDPEngine.sol';
import {StabilityFeeTreasury} from '../StabilityFeeTreasury.sol';
import {CoinJoin} from '../BasicTokenAdapters.sol';

contract Hevm {
    function warp(uint256) public;
}

contract Usr {
    function approveCDPModification(address cdpEngine, address lad) external {
        CDPEngine(cdpEngine).approveCDPModification(lad);
    }
    function giveFunds(address stabilityFeeTreasury, bytes32 transferType, address lad, uint rad) external {
        StabilityFeeTreasury(stabilityFeeTreasury).giveFunds(transferType, lad, rad);
    }
    function takeFunds(address stabilityFeeTreasury, bytes32 transferType, address lad, uint rad) external {
        StabilityFeeTreasury(stabilityFeeTreasury).takeFunds(transferType, lad, rad);
    }
    function pullFunds(address stabilityFeeTreasury, address gal, address tkn, uint wad) external {
        return StabilityFeeTreasury(stabilityFeeTreasury).pullFunds(gal, tkn, wad);
    }
    function approve(address systemCoin, address gal) external {
        Coin(systemCoin).approve(gal, uint(-1));
    }
}

contract StabilityFeeTreasuryTest is DSTest {
    Hevm hevm;

    CDPEngine cdpEngine;
    StabilityFeeTreasury stabilityFeeTreasury;

    Coin systemCoin;
    CoinJoin systemCoinA;

    Usr usr;

    address alice = address(0x1);
    address bob = address(0x2);

    uint constant WAD = 10 ** 18;
    uint constant RAY = 10 ** 27;

    function ray(uint wad) internal pure returns (uint) {
        return wad * 10 ** 9;
    }
    function rad(uint wad) internal pure returns (uint) {
        return wad * RAY;
    }

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        usr  = new Usr();

        cdpEngine  = new CDPEngine();
        systemCoin = new Coin("Coin", "COIN", 99);
        systemCoinA = new CoinJoin(address(cdpEngine), address(systemCoin));
        stabilityFeeTreasury = new StabilityFeeTreasury(address(cdpEngine), alice, address(systemCoinA), 0);

        systemCoin.addAuthorization(address(systemCoinA));
        stabilityFeeTreasury.addAuthorization(address(systemCoinA));

        cdpEngine.createUnbackedDebt(bob, address(stabilityFeeTreasury), rad(100 ether));
        cdpEngine.createUnbackedDebt(bob, address(this), rad(100 ether));

        cdpEngine.approveCDPModification(address(systemCoinA));
        systemCoinA.exit(address(this), 100 ether);

        usr.approveCDPModification(address(cdpEngine), address(stabilityFeeTreasury));
    }

    function test_setup() public {
        assertEq(stabilityFeeTreasury.surplusTransferDelay(), 0);
        assertEq(address(stabilityFeeTreasury.cdpEngine()), address(cdpEngine));
        assertEq(address(stabilityFeeTreasury.accountingEngine()), alice);
        assertEq(stabilityFeeTreasury.latestSurplusTransferTime(), now);
        assertEq(stabilityFeeTreasury.expensesMultiplier(), WAD);
        assertEq(systemCoin.balanceOf(address(this)), 100 ether);
        assertEq(cdpEngine.coinBalance(address(alice)), 0);
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(100 ether));
    }
    function test_modify_accounting_engine() public {
        stabilityFeeTreasury.modifyParameters("accountingEngine", bob);
        assertEq(stabilityFeeTreasury.accountingEngine(), bob);
    }
    function test_modify_params() public {
        stabilityFeeTreasury.modifyParameters("expensesMultiplier", 5 * WAD);
        stabilityFeeTreasury.modifyParameters("treasuryCapacity", rad(50 ether));
        stabilityFeeTreasury.modifyParameters("surplusTransferDelay", 10 minutes);
        assertEq(stabilityFeeTreasury.expensesMultiplier(), 5 * WAD);
        assertEq(stabilityFeeTreasury.treasuryCapacity(), rad(50 ether));
        assertEq(stabilityFeeTreasury.surplusTransferDelay(), 10 minutes);
    }
    function test_transferSurplusFunds_no_expenses_no_minimumFundsRequired() public {
        hevm.warp(now + 1 seconds);
        stabilityFeeTreasury.transferSurplusFunds();
        assertEq(stabilityFeeTreasury.accumulatorTag(), 0);
        assertEq(stabilityFeeTreasury.latestSurplusTransferTime(), now);
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), 0);
        assertEq(cdpEngine.coinBalance(address(alice)), rad(100 ether));
    }
    function test_transferSurplusFunds_no_expenses_with_minimumFundsRequired() public {
        stabilityFeeTreasury.modifyParameters("minimumFundsRequired", rad(50 ether));
        hevm.warp(now + 1 seconds);
        stabilityFeeTreasury.transferSurplusFunds();
        assertEq(stabilityFeeTreasury.accumulatorTag(), 0);
        assertEq(stabilityFeeTreasury.latestSurplusTransferTime(), now);
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(50 ether));
        assertEq(cdpEngine.coinBalance(address(alice)), rad(50 ether));
    }
    function test_transferSurplusFunds_no_expenses_both_internal_and_external_coins() public {
        assertEq(stabilityFeeTreasury.treasuryCapacity(), 0);
        assertEq(stabilityFeeTreasury.expensesMultiplier(), WAD);
        assertEq(stabilityFeeTreasury.expensesAccumulator(), 0);
        assertEq(stabilityFeeTreasury.minimumFundsRequired(), 0);
        systemCoin.transfer(address(stabilityFeeTreasury), 1 ether);
        assertEq(systemCoin.balanceOf(address(stabilityFeeTreasury)), 1 ether);
        hevm.warp(now + 1 seconds);
        stabilityFeeTreasury.transferSurplusFunds();
        assertEq(systemCoin.balanceOf(address(stabilityFeeTreasury)), 0);
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), 0);
        assertEq(cdpEngine.coinBalance(address(alice)), rad(101 ether));
    }
    function test_transferSurplusFunds_no_expenses_with_minimumFundsRequired_both_internal_and_external_coins() public {
        stabilityFeeTreasury.modifyParameters("minimumFundsRequired", rad(50 ether));
        assertEq(stabilityFeeTreasury.treasuryCapacity(), 0);
        assertEq(stabilityFeeTreasury.expensesMultiplier(), WAD);
        assertEq(stabilityFeeTreasury.expensesAccumulator(), 0);
        assertEq(stabilityFeeTreasury.minimumFundsRequired(), rad(50 ether));
        systemCoin.transfer(address(stabilityFeeTreasury), 1 ether);
        assertEq(systemCoin.balanceOf(address(stabilityFeeTreasury)), 1 ether);
        hevm.warp(now + 1 seconds);
        stabilityFeeTreasury.transferSurplusFunds();
        assertEq(systemCoin.balanceOf(address(stabilityFeeTreasury)), 0);
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(50 ether));
        assertEq(cdpEngine.coinBalance(address(alice)), rad(51 ether));
    }
    function test_allow() public {
        stabilityFeeTreasury.allow(alice, 10 ether);
        assertEq(stabilityFeeTreasury.allowance(alice), 10 ether);
    }
    function testFail_give_non_relied() public {
        usr.giveFunds(address(stabilityFeeTreasury), bytes32("INTERNAL"), address(usr), rad(5 ether));
    }
    function testFail_take_non_relied() public {
        stabilityFeeTreasury.giveFunds(bytes32("INTERNAL"), address(usr), rad(5 ether));
        usr.takeFunds(address(stabilityFeeTreasury), bytes32("INTERNAL"), address(usr), rad(2 ether));
    }
    function test_give_take_internal() public {
        assertEq(cdpEngine.coinBalance(address(usr)), 0);
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(100 ether));
        stabilityFeeTreasury.giveFunds(bytes32("INTERNAL"), address(usr), rad(5 ether));
        assertEq(cdpEngine.coinBalance(address(usr)), rad(5 ether));
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(95 ether));
        stabilityFeeTreasury.takeFunds(bytes32("INTERNAL"), address(usr), rad(2 ether));
        assertEq(cdpEngine.coinBalance(address(usr)), rad(3 ether));
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(97 ether));
        assertEq(stabilityFeeTreasury.expensesAccumulator(), rad(5 ether));
    }
    function test_give_take_external() public {
        assertEq(cdpEngine.coinBalance(address(usr)), 0);
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(100 ether));
        stabilityFeeTreasury.giveFunds(bytes32("EXTERNAL"), address(usr), 5 ether);
        assertEq(systemCoin.balanceOf(address(usr)), 5 ether);
        assertEq(systemCoin.balanceOf(address(stabilityFeeTreasury)), 95 ether);
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), 0);
        usr.approve(address(systemCoin), address(stabilityFeeTreasury));
        stabilityFeeTreasury.takeFunds(bytes32("EXTERNAL"), address(usr), 2 ether);
        assertEq(systemCoin.balanceOf(address(usr)), 3 ether);
        assertEq(systemCoin.balanceOf(address(stabilityFeeTreasury)), 97 ether);
        assertEq(stabilityFeeTreasury.expensesAccumulator(), rad(5 ether));
    }
    function testFail_pull_above_allow() public {
        stabilityFeeTreasury.allow(address(usr), rad(10 ether));
        usr.pullFunds(address(stabilityFeeTreasury), address(usr), address(stabilityFeeTreasury.systemCoin()), rad(11 ether));
    }
    function testFail_pull_null_tkn_amount() public {
        stabilityFeeTreasury.allow(address(usr), rad(10 ether));
        usr.pullFunds(
          address(stabilityFeeTreasury), address(usr), address(stabilityFeeTreasury.systemCoin()), 0
        );
    }
    function testFail_pull_null_account() public {
        stabilityFeeTreasury.allow(address(usr), rad(10 ether));
        usr.pullFunds(
          address(stabilityFeeTreasury), address(0), address(stabilityFeeTreasury.systemCoin()), rad(1 ether)
        );
    }
    function testFail_pull_random_tkn() public {
        stabilityFeeTreasury.allow(address(usr), rad(10 ether));
        usr.pullFunds(address(stabilityFeeTreasury), address(usr), address(0x3), rad(1 ether));
    }
    function test_pull_funds() public {
        stabilityFeeTreasury.allow(address(usr), 10 ether);
        usr.pullFunds(address(stabilityFeeTreasury), address(usr), address(stabilityFeeTreasury.systemCoin()), 1 ether);
        assertEq(stabilityFeeTreasury.allowance(address(usr)), 9 ether);
        assertEq(systemCoin.balanceOf(address(usr)), 1 ether);
        assertEq(systemCoin.balanceOf(address(stabilityFeeTreasury)), 99 ether);
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), 0);
        assertEq(stabilityFeeTreasury.expensesAccumulator(), rad(1 ether));
    }
    function testFail_transferSurplusFunds_before_surplusTransferDelay() public {
        stabilityFeeTreasury.modifyParameters("surplusTransferDelay", 10 minutes);
        hevm.warp(now + 9 minutes);
        stabilityFeeTreasury.transferSurplusFunds();
    }
    function test_transferSurplusFunds_after_expenses() public {
        stabilityFeeTreasury.modifyParameters("surplusTransferDelay", 10 minutes);
        stabilityFeeTreasury.giveFunds(bytes32("INTERNAL"), alice, rad(40 ether));
        hevm.warp(now + 10 minutes);
        stabilityFeeTreasury.transferSurplusFunds();
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(40 ether));
        assertEq(cdpEngine.coinBalance(address(alice)), rad(60 ether));
        hevm.warp(now + 10 minutes);
        stabilityFeeTreasury.transferSurplusFunds();
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), 0);
        assertEq(cdpEngine.coinBalance(address(alice)), rad(100 ether));
    }
    function test_transferSurplusFunds_after_expenses_with_minimumFundsRequired() public {
        stabilityFeeTreasury.modifyParameters("minimumFundsRequired", rad(30 ether));
        stabilityFeeTreasury.modifyParameters("surplusTransferDelay", 10 minutes);
        stabilityFeeTreasury.giveFunds(bytes32("INTERNAL"), alice, rad(40 ether));
        hevm.warp(now + 10 minutes);
        stabilityFeeTreasury.transferSurplusFunds();
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(40 ether));
        assertEq(cdpEngine.coinBalance(address(alice)), rad(60 ether));
        hevm.warp(now + 10 minutes);
        stabilityFeeTreasury.transferSurplusFunds();
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(30 ether));
        assertEq(cdpEngine.coinBalance(address(alice)), rad(70 ether));
    }
    function test_transferSurplusFunds_after_expenses_with_treasuryCapacity_and_minimumFundsRequired() public {
        stabilityFeeTreasury.modifyParameters("treasuryCapacity", rad(20 ether));
        stabilityFeeTreasury.modifyParameters("minimumFundsRequired", rad(30 ether));
        stabilityFeeTreasury.modifyParameters("surplusTransferDelay", 10 minutes);
        stabilityFeeTreasury.giveFunds(bytes32("INTERNAL"), alice, rad(40 ether));
        hevm.warp(now + 10 minutes);
        stabilityFeeTreasury.transferSurplusFunds();
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(30 ether));
        assertEq(cdpEngine.coinBalance(address(alice)), rad(70 ether));
        hevm.warp(now + 10 minutes);
        stabilityFeeTreasury.transferSurplusFunds();
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(30 ether));
        assertEq(cdpEngine.coinBalance(address(alice)), rad(70 ether));
    }
    function test_treasuryCapacity_and_minimumFundsRequired_bigger_than_treasury_amount() public {
        stabilityFeeTreasury.modifyParameters("treasuryCapacity", rad(120 ether));
        stabilityFeeTreasury.modifyParameters("minimumFundsRequired", rad(130 ether));
        stabilityFeeTreasury.modifyParameters("surplusTransferDelay", 10 minutes);
        stabilityFeeTreasury.giveFunds(bytes32("INTERNAL"), alice, rad(40 ether));
        hevm.warp(now + 10 minutes);
        stabilityFeeTreasury.transferSurplusFunds();
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(60 ether));
        assertEq(cdpEngine.coinBalance(address(alice)), rad(40 ether));
        hevm.warp(now + 10 minutes);
        stabilityFeeTreasury.transferSurplusFunds();
        assertEq(cdpEngine.coinBalance(address(stabilityFeeTreasury)), rad(60 ether));
        assertEq(cdpEngine.coinBalance(address(alice)), rad(40 ether));
    }
}