/// vox.t.sol -- test for vox.sol

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
import "ds-token/token.sol";

import {Mai} from "../mai.sol";
import {Vat} from '../vat.sol';
import {Jug} from "../jug.sol";
import {Vow} from '../vow.sol';
import {Vox} from '../vox.sol';
import {GemJoin} from '../join.sol';
import {Spotter} from '../spot.sol';
import {Exp} from "../exp.sol";

contract Feed {
    bytes32 public val;
    bool public has;
    constructor(uint256 initVal, bool initHas) public {
        val = bytes32(initVal);
        has = initHas;
    }
    function poke(uint256 val_) external {
        val = bytes32(val_);
    }
    function peek() external view returns (bytes32, bool) {
        return (val, has);
    }
}

contract Hevm {
    function warp(uint256) public;
}

contract VoxTest is DSTest {
    Vat     vat;
    Spotter spot;
    Jug jug;
    Vox vox;
    Feed stableFeed;

    GemJoin gemA;
    DSToken gold;
    Feed    goldFeed;

    Mai     token;
    Hevm    hevm;

    address vow;
    address self;

    uint constant SPY = 31536000;

    function ray(uint wad) internal pure returns (uint) {
        return wad * 10 ** 9;
    }

    function rad(uint wad) internal pure returns (uint) {
        return wad * 10 ** 27;
    }

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        vow = address(0x123456789);

        vat = new Vat();
        spot = new Spotter(address(vat));
        vat.rely(address(spot));

        jug = new Jug(address(vat));
        vat.rely(address(jug));
        jug.init("gold");
        jug.file("gold", "duty", 0);
        jug.file("base", ray(1 ether));
        jug.file("vow", address(vow));

        gold = new DSToken("GEM");
        gold.mint(1000 ether);
        vat.init("gold");
        goldFeed = new Feed(1 ether, true);
        spot.file("gold", "pip", address(goldFeed));
        spot.file("gold", "mat", 1000000000000000000000000000);
        spot.poke("gold");
        gemA = new GemJoin(address(vat), "gold", address(gold));

        vat.file("gold", "line", rad(1000 ether));
        vat.file("Line",         rad(1000 ether));

        gold.approve(address(gemA));
        gold.approve(address(vat));

        vat.rely(address(gemA));

        gemA.join(address(this), 1000 ether);

        token = createToken();
        stableFeed = new Feed(1 ether, true);

        vox = new Vox(address(token), address(spot));
        vox.file("pip", address(stableFeed));
        vox.file("jug", address(jug));
        vox.file("trim", 5 * 10 ** 24);
        token.rely(address(vox));
        jug.rely(address(vox));

        spot.rely(address(token));
        vat.rely(address(token));

        token.file("vow", address(vow));
        token.file("spot", address(spot));

        token.mint(address(this), 1000);

        self = address(this);

        vat.frob("gold", self, self, self, 10 ether, 5 ether);
    }

    function gem(bytes32 ilk, address urn) internal view returns (uint) {
        return vat.gem(ilk, urn);
    }
    function ink(bytes32 ilk, address urn) internal view returns (uint) {
        (uint ink_, uint art_) = vat.urns(ilk, urn); art_;
        return ink_;
    }
    function art(bytes32 ilk, address urn) internal view returns (uint) {
        (uint ink_, uint art_) = vat.urns(ilk, urn); ink_;
        return art_;
    }

    function createToken() internal returns (Mai) {
        return new Mai(99, address(vat));
    }

    function testSetup() public {
        assertTrue(address(vox.tkn()) == address(token));
        assertTrue(address(vox.jug()) == address(jug));
        assertTrue(address(vox.spot()) == address(spot));
    }

    function testProdNoDeviation() public {
        token.drip();
        jug.drip();
        vox.back();
        assertEq(vox.mpr(), ray(1 ether));
        assertEq(token.msr(), ray(1 ether));
    }

    function testFailNoDripping() public {
        token.drip();
        jug.drip();
        vox.back();
        hevm.warp(now + 1 seconds);
        vox.back();
    }

    function testFailRestBetweenBacks() public {
        vox.file("rest", 600);
        token.drip();
        jug.drip();
        vox.back();
        token.drip();
        jug.drip();
        vox.back();
    }

    function testRestBetweenBacks() public {
        vox.file("rest", 600);
        vox.back();
        hevm.warp(now + 600 seconds);
        token.drip();
        jug.drip();
        vox.back();
    }

    function testBackNegativeDeviation() public {
        stableFeed.poke(0.995 ether);
        token.drip();
        jug.drip();
        vox.back();
        assertEq(token.rho(), now);
        assertEq(vox.mpr(), ray(0.995 ether));
        assertEq(spot.par(), ray(1 ether));
        assertEq(token.msr(), 1000000000158153903837946258);
        assertEq(jug.base(), 1000000000158153903837946258);
        hevm.warp(now + SPY * 1 seconds);
        assertTrue(now > token.rho());
        token.drip();
        jug.drip();
        (, uint rho) = jug.ilks("gold");
        assertEq(rho, now);
        assertEq(spot.par(), 1004999999999999999993941765);
        assertEq(vat.mai(address(vow)), 24999999999999999969708825000000000000000000);
        assertEq(vat.sin(address(vow)), 4999999999999999993941765000);
        assertEq(vat.mai(address(token)), 4999999999999999993941765000);
        assertEq(vat.vice(), 4999999999999999993941765000);
        assertEq(vat.debt(), 5025000000000000004969708824999999993941765000);
    }

    function testBackPositiveDeviation() public {
        stableFeed.poke(1.005 ether);
        vox.back();
        assertEq(token.rho(), now);
        assertEq(vox.mpr(), ray(1.005 ether));
        assertEq(spot.par(), ray(1 ether));
        assertEq(token.msr(), 999999999841846096162053742);
        assertEq(jug.base(), 999999999841846096162053742);
        hevm.warp(now + SPY * 1 seconds);
        assertTrue(now > token.rho());
        token.drip();
        jug.drip();
        (, uint rho) = jug.ilks("gold");
        assertEq(rho, now);
        assertEq(spot.par(), 995024875621105672471661507);
        assertEq(vat.mai(address(vow)), -24875621894471637641692465000000000000000000);
        assertEq(vat.sin(address(vow)), -4975124378894327528338493000);
        assertEq(vat.mai(address(token)), -4975124378894327528338493000);
        assertEq(vat.vice(), -4975124378894327528338493000);
        assertEq(vat.debt(), 4975124378105528357383183156105672471661507000);
    }

    function testRateSpread() public {
        vox.file("span", ray(2 ether));

        stableFeed.poke(0.995 ether);
        vox.back();

        assertEq(spot.par(), ray(1 ether));
        assertEq(token.msr(), 1000000000079175551708715275);
        assertEq(jug.base(), 1000000000158153903837946258);
        hevm.warp(now + SPY * 1 seconds);

        jug.drip();
        token.drip();

        assertEq(spot.par(), 1002499999999999999998720538);
        assertEq(vat.mai(address(vow)), 24999999999999999969708825000000000000000000);
        assertEq(vat.sin(address(vow)), 2499999999999999998720538000);
        assertEq(vat.mai(address(token)), 2499999999999999998720538000);
        assertEq(vat.vice(), 2499999999999999998720538000);
        assertEq(vat.debt(), 5025000000000000002469708824999999998720538000);

        stableFeed.poke(1.005 ether);
        vox.back();

        assertEq(token.msr(), 999999999841846096162053742);
        assertEq(jug.base(), 999999999920824448291284725);

        hevm.warp(now + SPY * 1 seconds);
        jug.drip();
        token.drip();

        assertEq(spot.par(), 997512437810158436651567564);
        assertEq(vat.mai(address(vow)), 12468827929183639250826420000000000000000000);
        assertEq(vat.sin(address(vow)), -2487562189841563348432436000);
        assertEq(vat.mai(address(token)), -2487562189841563348432436000);
        assertEq(vat.vice(), -2487562189841563348432436000);
        assertEq(vat.debt(), 5012468827929183636763264230158436651567564000);
    }

    function testMultiHikePositiveDeviation() public {
        vox.file("hike", ray(1.00000005 ether));
        stableFeed.poke(0.995 ether);
        vox.back();
        assertEq(vox.bowl(), 0);
        assertEq(vox.path(), 1);

        hevm.warp(now + SPY * 1 seconds);
        jug.drip();
        token.drip();
        vox.back();

        assertEq(vox.bowl(), 31536000);
        assertEq(vox.path(), 1);
        assertEq(spot.par(), 1004999999999999999993941765);
        assertEq(vat.mai(address(vow)), 24999999999999999969708825000000000000000000);
        assertEq(vat.sin(address(vow)), 4999999999999999993941765000);
        assertEq(vat.mai(address(token)), 4999999999999999993941765000);
        assertEq(vat.vice(), 4999999999999999993941765000);
        assertEq(vat.debt(), 5025000000000000004969708824999999993941765000);

        hevm.warp(now + SPY * 1 seconds);
        jug.drip();
        token.drip();
        vox.back();

        assertEq(vox.bowl(), 63072000);
        assertEq(vox.path(), 1);
        assertEq(spot.par(), 4839323606636171096946428139);
        assertEq(vat.mai(address(vow)), 19196618033180855484732140695000000000000000000);
        assertEq(vat.sin(address(vow)), 3839323606636171096946428139000);
        assertEq(vat.mai(address(token)), 3839323606636171096946428139000);
        assertEq(vat.vice(), 3839323606636171096946428139000);
        assertEq(vat.debt(), 24196618033180859324055747331171096946428139000);
    }

    function testMultiHikeNegativeDeviation() public {
        vox.file("hike", ray(1.00000005 ether));
        stableFeed.poke(1.005 ether);
        vox.back();
        assertEq(vox.bowl(), 0);
        assertEq(vox.path(), -1);

        hevm.warp(now + SPY * 1 seconds);
        jug.drip();
        token.drip();
        vox.back();

        assertEq(vox.bowl(), 31536000);
        assertEq(vox.path(), -1);
        assertEq(spot.par(), 995024875621105672471661507);
        assertEq(vat.mai(address(vow)), -24875621894471637641692465000000000000000000);
        assertEq(vat.sin(address(vow)), -4975124378894327528338493000);
        assertEq(vat.mai(address(token)), -4975124378894327528338493000);
        assertEq(vat.vice(), -4975124378894327528338493000);
        assertEq(vat.debt(), 4975124378105528357383183156105672471661507000);

        hevm.warp(now + SPY * 1 seconds);
        jug.drip();
        token.drip();
        vox.back();

        assertEq(vox.bowl(), 63072000);
        assertEq(vox.path(), -1);
        assertEq(spot.par(), 204584308297806743096017755);
        assertEq(vat.mai(address(vow)), -3977078458510966284519911225000000000000000000);
        assertEq(vat.sin(address(vow)), -795415691702193256903982245000);
        assertEq(vat.mai(address(token)), -795415691702193256903982245000);
        assertEq(vat.vice(), -795415691702193256903982245000);
        assertEq(vat.debt(), 1022921541489032920064397072806743096017755000);
    }

    function testBackParPositive() public {
        vox.file("fury", 1);
        stableFeed.poke(0.995 ether);
        vox.back();
        assertEq(token.rho(), now);
        (, uint oldGoldRho) = jug.ilks("gold");
        assertEq(oldGoldRho, now);
        assertEq(token.msr(), 1000000000158153903837946258);
        assertEq(jug.base(), 1000000000158153903837946258);
        hevm.warp(now + SPY * 1 seconds);
        token.drip();
        jug.drip();
        stableFeed.poke(1.003 ether);
        vox.back();
        assertEq(token.rho(), now);
        (, uint newGoldRho) = jug.ilks("gold");
        assertEq(newGoldRho, now);
        assertTrue(newGoldRho > oldGoldRho);
        assertEq(vox.mpr(), ray(1.003 ether));
        assertEq(spot.par(), 1004999999999999999993941765);
        assertEq(token.msr(), 999999999841846096162053743);
        assertEq(jug.base(), 999999999841846096162053743);
        hevm.warp(now + SPY * 1 seconds);
        assertTrue(now > token.rho());
        token.drip();
        jug.drip();
        assertEq(spot.par(), 999999999999211200859527677);
        assertEq(vat.mai(address(vow)), -3943995702361615000000000000000000);
        assertEq(vat.sin(address(vow)), -788799140472323000);
        assertEq(vat.mai(address(token)), -788799140472323000);
        assertEq(vat.vice(), -788799140472323000);
        assertEq(vat.debt(), 4999999999996056004297638384211200859527677000);
    }

    function testBackParNegative() public {
        vox.file("fury", 1);
        stableFeed.poke(1.005 ether);
        vox.back();
        hevm.warp(now + SPY * 1 seconds);
        token.drip();
        jug.drip();
        stableFeed.poke(0.997 ether);
        vox.back();
        assertEq(token.rho(), now);
        assertEq(vox.mpr(), ray(0.997 ether));
        assertEq(spot.par(), 995024875621105672471661507);
        assertEq(token.msr(), 1000000000157369017735302294);
        assertEq(jug.base(), 1000000000157369017735302294);
        hevm.warp(now + SPY * 1 seconds);
        assertTrue(now > token.rho());
        token.drip();
        jug.drip();
        assertEq(spot.par(), 999975248137414531327262378);
        assertEq(vat.mai(address(vow)), -123759312927343363688110000000000000000000);
        assertEq(vat.sin(address(vow)), -24751862585468672737622000);
        assertEq(vat.mai(address(token)), -24751862585468672737622000);
        assertEq(vat.vice(), -24751862585468672737622000);
        assertEq(vat.debt(), 4999876240687072656611560027414531327262378000);
    }

    function test_no_par_back_other_side_deviation() public {
        vox.file("fury", 1);
        stableFeed.poke(1.005 ether);
        vox.back();
        hevm.warp(now + SPY * 1 seconds);
        token.drip();
        jug.drip();
        stableFeed.poke(1.003 ether);
        vox.back();
        assertEq(token.rho(), now);
        assertEq(vox.mpr(), ray(1.003 ether));
        assertEq(token.msr(), ray(1 ether));
        assertEq(jug.base(), ray(1 ether));
    }

    function test_bounded_stability_fee() public {
        vox.file("up", ray(1 ether));
        vox.file("down", 999999999999999999999999999);
        stableFeed.poke(1.005 ether);
        vox.back();
        assertEq(jug.base(), 999999999999999999999999999);
        stableFeed.poke(0.995 ether);
        vox.back();
        assertEq(jug.base(), ray(1 ether));
    }

    function test_custom_per_second_rates() public {
        vox.file("dawn", 1000000000158153903837946258);
        vox.file("dusk", ray(1 ether) + 1);
        vox.back();
        assertEq(token.msr(), ray(1 ether) + 1);
        assertEq(jug.base(), 1000000000158153903837946258);
    }
}
