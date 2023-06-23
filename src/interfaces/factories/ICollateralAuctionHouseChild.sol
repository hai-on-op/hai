// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IIncreasingDiscountCollateralAuctionHouse} from '@interfaces/IIncreasingDiscountCollateralAuctionHouse.sol';

import {IFactoryChild} from '@interfaces/factories/IFactoryChild.sol';

interface ICollateralAuctionHouseChild is IIncreasingDiscountCollateralAuctionHouse, IFactoryChild {}
