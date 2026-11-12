// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IDepositPool {
    function stake(uint256 poolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external payable;
    function getLatestUserReward(uint256 poolIndex_, address user_) external view returns (uint256);
    function getLatestReferrerReward(uint256 poolIndex_, address user_) external view returns (uint256);
    function referrersData(address, uint256)
        external
        view
        returns (uint256 amountStaked, uint256 virtualAmountStaked, uint256 rate, uint256 pendingRewards, uint128 lastClaim);
    function rewardPoolsData(uint256)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    function referrerTiers(uint256, uint256) external view returns (uint256 amount, uint256 multiplier);
}

interface IDistributor {
    function distributeRewards(uint256 poolIndex_) external;
    function distributedRewards(uint256, address) external view returns (uint256);
    function depositPools(uint256, address)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IChainLinkDataConsumer {
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256);
}

/// @notice Morpheus 0C lane 1 — referrer-tier decimals mismatch + self-referral.
/// Fork: ETH mainnet block 26400696 (BlastAPI; publicnode 403s archive reads,
/// llamarcp 525s on foundry's HTTP client). No mainnet tx; local fork only.
///
/// HARNESS NOTE 1: the Aave V3 Pool impl (0x4295Fe69...) cannot execute on this
/// foundry 1.8.5 fork — every delegatecall into it reverts `NotActivated`
/// (see test/AaveProbe.t.sol). The Distributor's `supply()`/`withdraw()` call
/// Aave for AAVE-strategy pools, so the harness flips ONLY the two tested
/// pools' `strategy` to NONE (0) via vm.store on the Distributor's
/// `depositPools` mapping (slot 201; struct offsets verified against live
/// `deposited` values in testLayoutSanity). NONE only changes WHERE yield
/// comes from (token balance instead of aToken balance); the DepositPool's
/// referrer-tier / rate / reward math under test is untouched. Yield is
/// simulated by dealing extra tokens to the Distributor before distribution.
///
/// HARNESS NOTE 2: the ChainLinkDataConsumer returns price 0 when
/// `block.timestamp - updatedAt > allowedPriceUpdateDelay` (1h for ETH/USD,
/// 24h for USDT/USD). Any warp past the 1-day distribution gate makes the
/// pinned feed data stale, so `distributeRewards` would revert on the fork
/// (live, feeds update every few minutes). The harness mocks ONLY the
/// consumer's `getChainLinkDataFeedLatestAnswer` to return the exact live
/// tokenPrice values read from the Distributor at the fork block — the oracle
/// input, not any Morpheus logic.
contract ReferrerTiersTest is Test {
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant WETH_POOL = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant WBTC_POOL = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant USDC_POOL = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant CLC = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address constant A = address(0xA11CE);
    address constant C = address(0xC0110);
    address constant R = address(0x9EFE99E9);
    address constant R2 = address(0x9EFE22E2);

    function setUp() public {
        vm.createSelectFork("https://eth-mainnet.public.blastapi.io", 26_400_696);
        vm.deal(A, 100 ether);
        vm.deal(C, 100 ether);
        vm.deal(R, 10 ether);
        vm.deal(R2, 10 ether);
        _mockPrices();
    }

    /// @notice Sanity: my computed `depositPools` storage layout matches live state.
    function testLayoutSanity() public view {
        bytes32 base = _poolBaseSlot(USDC_POOL);
        uint256 deposited = uint256(vm.load(DIST, bytes32(uint256(base) + 3)));
        uint256 lastBal = uint256(vm.load(DIST, bytes32(uint256(base) + 4)));
        uint256 strategy = uint256(vm.load(DIST, bytes32(uint256(base) + 5))) & 0xff;
        console.log("USDC deposited:", deposited);
        console.log("USDC lastUnderlyingBalance:", lastBal);
        console.log("USDC strategy:", strategy);
        assertEq(deposited, 628270346411, "layout: deposited must match live USDC pool");
        assertEq(lastBal, 628270346410, "layout: lastUnderlyingBalance must match live USDC pool");
        assertEq(strategy, 2, "layout: strategy must be AAVE(2) live");
    }

    /// @notice H-TIER: USDC referrer tiers are unreachable — thresholds are written
    /// in 18-decimal units (4,000 / 10,000 / 100,000 / 250,000 USDC) while
    /// `amountStaked` is tracked in native 6-decimal units, so the lowest tier
    /// (4e21) exceeds the entire USDC supply in native units (~7e16).
    function testUSDCTiersUnreachable() public {
        _flipToNone(USDC_POOL);
        deal(USDC, DIST, 1000e6); // buffer so _withdrawYield (if any) can pay out
        // Refer 300,000 USDC — above the INTENDED tier-3 threshold (250,000 USDC).
        deal(USDC, A, 300_000e6);
        vm.startPrank(A);
        IERC20(USDC).approve(DIST, type(uint256).max);
        IDepositPool(USDC_POOL).stake(0, 300_000e6, 0, R);
        vm.stopPrank();

        (uint256 amountStaked, uint256 virtualStaked,,,) = IDepositPool(USDC_POOL).referrersData(R, 0);
        (uint256 tier0Amount,) = IDepositPool(USDC_POOL).referrerTiers(0, 0);
        console.log("USDC referrer amountStaked (native 6-dec):", amountStaked);
        console.log("USDC tier0 threshold:", tier0Amount);
        console.log("USDC referrer virtualAmountStaked:", virtualStaked);
        assertEq(amountStaked, 300_000e6, "referrer amountStaked should be 300k USDC in native units");
        assertEq(virtualStaked, 0, "BUG: referrer virtual is 0 despite 300k USDC referred");
        assertGt(tier0Amount, 7e16, "tier0 exceeds total USDC supply in native units -> unreachable");

        // Simulate yield so the pool gets a MOR allocation, then distribute.
        // NOTE: for a NONE pool, yield = Distributor token balance minus
        // lastUnderlyingBalance, and lastUnderlyingBalance already includes
        // the pre-existing 628,270 USDC (held in Aave, not as USDC here).
        // So the Distributor's USDC balance must be topped up past
        // lastUnderlyingBalance + simulated yield, not just +50k on top of
        // the stake.
        (,,, , uint256 lastBal,,,) = IDistributor(DIST).depositPools(0, USDC_POOL);
        deal(USDC, DIST, lastBal + 50_000e6);
        vm.warp(block.timestamp + 2 days);
        IDistributor(DIST).distributeRewards(0);

        uint256 refReward = IDepositPool(USDC_POOL).getLatestReferrerReward(0, R);
        uint256 userReward = IDepositPool(USDC_POOL).getLatestUserReward(0, A);
        console.log("USDC referrer pending MOR reward:", refReward);
        console.log("USDC staker pending MOR reward:", userReward);
        assertEq(refReward, 0, "BUG: referrer earns 0 MOR in the USDC pool");
        assertGt(userReward, 0, "staker rewards DO accrue in the USDC pool (pool itself works)");
    }

    /// @notice Positive control: the same tiers WORK in the 18-decimal wETH pool.
    function testWETHTiersReachable() public {
        _flipToNone(WETH_POOL);
        deal(WETH, DIST, 1 ether); // buffer for _withdrawYield payout
        deal(WETH, A, 100 ether);
        vm.startPrank(A);
        IERC20(WETH).approve(DIST, type(uint256).max);
        IDepositPool(WETH_POOL).stake(0, 100 ether, 0, R2);
        vm.stopPrank();

        (uint256 amountStaked, uint256 virtualStaked,,,) = IDepositPool(WETH_POOL).referrersData(R2, 0);
        console.log("wETH referrer amountStaked:", amountStaked);
        console.log("wETH referrer virtualAmountStaked:", virtualStaked);
        assertEq(amountStaked, 100 ether, "referrer amountStaked should be 100 wETH");
        assertEq(virtualStaked, 15 ether, "tier 3 (15%) virtual should be 15 wETH");

        deal(WETH, DIST, IERC20(WETH).balanceOf(DIST) + 50 ether); // simulated yield
        vm.warp(block.timestamp + 2 days);
        IDistributor(DIST).distributeRewards(0);

        uint256 refReward = IDepositPool(WETH_POOL).getLatestReferrerReward(0, R2);
        console.log("wETH referrer pending MOR reward:", refReward);
        assertGt(refReward, 0, "referrer DOES earn MOR in the wETH pool (control)");
    }

    /// @notice H2 (secondary): self-referral — stake() accepts referrer == staker.
    /// Self-referrer gets the 1% user bonus AND referrer-tier virtual on own stake.
    function testSelfReferral() public {
        _flipToNone(WETH_POOL);
        deal(WETH, DIST, 1 ether);
        deal(WETH, A, 100 ether);
        deal(WETH, C, 100 ether);
        vm.startPrank(A);
        IERC20(WETH).approve(DIST, type(uint256).max);
        IDepositPool(WETH_POOL).stake(0, 100 ether, 0, A); // referrer = self
        vm.stopPrank();
        vm.startPrank(C);
        IERC20(WETH).approve(DIST, type(uint256).max);
        IDepositPool(WETH_POOL).stake(0, 100 ether, 0, address(0)); // no referrer
        vm.stopPrank();

        deal(WETH, DIST, IERC20(WETH).balanceOf(DIST) + 50 ether); // simulated yield
        vm.warp(block.timestamp + 2 days);
        IDistributor(DIST).distributeRewards(0);

        uint256 selfUser = IDepositPool(WETH_POOL).getLatestUserReward(0, A);
        uint256 selfRef = IDepositPool(WETH_POOL).getLatestReferrerReward(0, A);
        uint256 ctrlUser = IDepositPool(WETH_POOL).getLatestUserReward(0, C);
        console.log("self-referrer user reward:", selfUser);
        console.log("self-referrer referrer reward:", selfRef);
        console.log("control user reward:", ctrlUser);
        console.log("self total:", selfUser + selfRef);
        assertGt(selfRef, 0, "self-referrer earns referrer rewards on own stake");
        assertGt(selfUser, ctrlUser, "self-referrer user reward exceeds control (1% bonus)");
        assertGt(selfUser + selfRef, ctrlUser, "self-referrer total exceeds identical control stake");
    }

    // ---- harness helpers ----

    /// @dev depositPools is DistributorV2 storage slot 201 (OZ 4.x layout:
    /// Initializable slot 0 + 50 gap, Ownable _owner slot 51 + 49 gap,
    /// UUPS gap 101-150, ERC1967Upgrade gap 151-200; verified against live
    /// chainLinkDataConsumer/rewardPool/l1Sender at slots 207-209).
    /// Struct offsets: token +0, chainLinkPath +1, tokenPrice +2,
    /// deposited +3, lastUnderlyingBalance +4, strategy/aToken/isExist
    /// PACKED at +5 (strategy = lowest byte).
    function _poolBaseSlot(address pool_) internal pure returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(pool_, keccak256(abi.encode(uint256(0), uint256(201)))));
        return inner;
    }

    function _flipToNone(address pool_) internal {
        bytes32 base = _poolBaseSlot(pool_);
        bytes32 slot = bytes32(uint256(base) + 5);
        uint256 packed = uint256(vm.load(DIST, slot));
        vm.store(DIST, slot, bytes32(packed & ~uint256(0xff))); // Strategy.NONE, keep aToken/isExist
        (,,,,, uint8 strat,,) = IDistributor(DIST).depositPools(0, pool_);
        assertEq(uint256(strat), 0, "harness: strategy flip failed");
    }

    /// @dev Mock the Chainlink consumer to return the exact live tokenPrice
    /// for each pool's path (see HARNESS NOTE 2). pathId = keccak256(path).
    function _mockPrices() internal {
        address[5] memory pools = [STETH_POOL, WETH_POOL, WBTC_POOL, USDC_POOL, USDT_POOL];
        for (uint256 i = 0; i < pools.length; i++) {
            (, string memory path, uint256 price,,,,,) = IDistributor(DIST).depositPools(0, pools[i]);
            vm.mockCall(
                CLC,
                abi.encodeWithSelector(
                    IChainLinkDataConsumer.getChainLinkDataFeedLatestAnswer.selector, keccak256(bytes(path))
                ),
                abi.encode(price)
            );
        }
    }
}
