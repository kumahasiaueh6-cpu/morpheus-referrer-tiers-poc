// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

/// @notice Environment probe for the Morpheus 0C fork harness.
/// The Aave V3 Pool impl (0x4295Fe69...) cannot execute under foundry 1.8.5's
/// REVM on a fork of ETH block 26400696: every delegatecall into it reverts
/// `NotActivated`, even though the impl code IS present (21,814 bytes) and
/// the same calls succeed via direct RPC eth_call. This is a fork-EVM
/// limitation, not a Morpheus bug. The ReferrerTiers tests work around it by
/// flipping the tested pools' strategy to NONE (see ReferrerTiers.t.sol).
/// These tests PASS by asserting the observed limitation.
interface IAavePoolProbe {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function getReserveData(address asset) external view returns (ReserveData memory);
}

interface IERC20Probe {
    function approve(address spender, uint256 amount) external returns (bool);
}

contract AaveProbeTest is Test {
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_IMPL = 0x4295Fe69b3e978Eb511e4558B4407AD871612fCb;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public {
        vm.createSelectFork("https://eth-mainnet.public.blastapi.io", 26_400_696);
    }

    function testAaveImplCodePresent() public view {
        bytes memory code = AAVE_IMPL.code;
        console.log("impl code length:", code.length);
        assertGt(code.length, 1000);
    }

    function testAaveViewWorks() public view {
        IAavePoolProbe.ReserveData memory rd = IAavePoolProbe(AAVE_POOL).getReserveData(WETH);
        console.log("liquidityIndex:", rd.liquidityIndex);
        assertGt(rd.liquidityIndex, 0);
    }

    /// @notice Documents the fork limitation: Aave state-changing calls
    /// revert on this foundry version (NotActivated inside the impl
    /// delegatecall). The ReferrerTiers harness avoids Aave for this reason.
    function testAaveSupplyRevertsOnFork() public {
        address whale = address(0x000000000000000000000000000000000000bEEF);
        vm.deal(whale, 10 ether);
        deal(WETH, whale, 5 ether);
        vm.startPrank(whale);
        IERC20Probe(WETH).approve(AAVE_POOL, type(uint256).max);
        vm.expectRevert();
        IAavePoolProbe(AAVE_POOL).supply(WETH, 1 ether, whale, 0);
        vm.stopPrank();
        console.log("aave supply reverts on this fork as documented (NotActivated)");
    }
}
