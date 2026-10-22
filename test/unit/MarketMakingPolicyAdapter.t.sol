// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {MarketMakingPolicyAdapter} from "../../src/bundler/MarketMakingPolicyAdapter.sol";
import {MarketMakingPolicy} from "../../src/ratifiers/policies/MarketMakingPolicy.sol";
import {PausableMarketMakingPolicy} from "../../src/ratifiers/policies/PausableMarketMakingPolicy.sol";
import {IMarketMakingPolicy} from "../../src/ratifiers/interfaces/IMarketMakingPolicy.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {IBundler3, Call} from "@bundler3/interfaces/IBundler3.sol";
import {ErrorsLib} from "@bundler3/libraries/ErrorsLib.sol";
import {Fixtures} from "../helpers/Fixtures.sol";

abstract contract MarketMakingPolicyAdapterTestBase is Fixtures {
    MarketMakingPolicyAdapter internal adapter;
    IMarketMakingPolicy internal policy;
    Midnight internal midnight;
    IBundler3 internal bundler3;

    address internal user;
    address internal unauthorized;

    bytes32 internal constant TENOR_MARKET_ID = keccak256("tenor-market");

    function setUp() public virtual {
        user = makeAddr("User");
        unauthorized = makeAddr("Unauthorized");

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        bundler3 = deployBundler3();
        adapter = new MarketMakingPolicyAdapter(address(bundler3));
        policy = _deployPolicy();

        vm.prank(user);
        midnight.setIsAuthorized(address(adapter), true, user);
    }

    function _deployPolicy() internal virtual returns (IMarketMakingPolicy);

    function _points() internal pure returns (IMarketMakingPolicy.CurvePoint[] memory points) {
        points = new IMarketMakingPolicy.CurvePoint[](2);
        points[0] = IMarketMakingPolicy.CurvePoint({ttm: 7 days, sellRate: 1e9, buyRate: 2e9});
        points[1] = IMarketMakingPolicy.CurvePoint({ttm: 30 days, sellRate: 3e9, buyRate: 4e9});
    }

    function _setCurveCall(bytes32 tenorMarketId, IMarketMakingPolicy.CurvePoint[] memory points)
        internal
        view
        returns (Call[] memory calls)
    {
        calls = new Call[](1);
        calls[0] = _call(
            address(adapter), abi.encodeCall(adapter.marketMakingSetCurve, (address(policy), tenorMarketId, points))
        );
    }

    function _clearCurveCall(bytes32 tenorMarketId) internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] =
            _call(address(adapter), abi.encodeCall(adapter.marketMakingClearCurve, (address(policy), tenorMarketId)));
    }

    /// @dev The public array getter reverts with empty data when the curve has no points.
    function _assertNoCurve(IMarketMakingPolicy target, address who, bytes32 tenorMarketId) internal view {
        (bool success, bytes memory returnData) =
            address(target).staticcall(abi.encodeCall(IMarketMakingPolicy.curves, (who, tenorMarketId, 0)));
        assertFalse(success, "curve has points");
        assertEq(returnData.length, 0, "unexpected revert data");
    }

    function test_constructor_revertsZeroBundler3() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new MarketMakingPolicyAdapter(address(0));
    }

    function test_marketMakingSetCurve_storesForInitiator() public {
        vm.prank(user);
        bundler3.multicall(_setCurveCall(TENOR_MARKET_ID, _points()));

        IMarketMakingPolicy.CurvePoint[] memory points = _points();
        for (uint256 i = 0; i < points.length; i++) {
            (uint32 ttm, uint112 sellRate, uint112 buyRate) = policy.curves(user, TENOR_MARKET_ID, i);
            assertEq(ttm, points[i].ttm);
            assertEq(sellRate, points[i].sellRate);
            assertEq(buyRate, points[i].buyRate);
        }
        _assertNoCurve(policy, address(adapter), TENOR_MARKET_ID);
    }

    function test_marketMakingSetCurve_pinsOnBehalfToInitiator() public {
        address attacker = makeAddr("Attacker");

        vm.prank(attacker);
        midnight.setIsAuthorized(address(adapter), true, attacker);

        vm.prank(attacker);
        bundler3.multicall(_setCurveCall(TENOR_MARKET_ID, _points()));

        (uint32 attackerTtm,,) = policy.curves(attacker, TENOR_MARKET_ID, 0);
        assertEq(attackerTtm, _points()[0].ttm, "curve landed on initiator");
        _assertNoCurve(policy, user, TENOR_MARKET_ID);
    }

    function test_marketMakingSetCurve_writesOnlyGivenPolicy() public {
        IMarketMakingPolicy other = new MarketMakingPolicy(address(midnight));

        vm.prank(user);
        bundler3.multicall(_setCurveCall(TENOR_MARKET_ID, _points()));

        _assertNoCurve(other, user, TENOR_MARKET_ID);
    }

    function test_marketMakingSetCurve_emitsEvent() public {
        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(policy));
        emit IMarketMakingPolicy.CurveSet(user, TENOR_MARKET_ID, _points());
        bundler3.multicall(_setCurveCall(TENOR_MARKET_ID, _points()));
    }

    function test_marketMakingSetCurve_bubblesPolicyValidation() public {
        IMarketMakingPolicy.CurvePoint[] memory crossed = _points();
        crossed[1].sellRate = crossed[1].buyRate + 1;

        vm.prank(user);
        vm.expectRevert(IMarketMakingPolicy.CrossedCurve.selector);
        bundler3.multicall(_setCurveCall(TENOR_MARKET_ID, crossed));
    }

    function test_marketMakingSetCurve_unauthorizedInitiator_policyReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(IMarketMakingPolicy.Unauthorized.selector);
        bundler3.multicall(_setCurveCall(TENOR_MARKET_ID, _points()));
    }

    function test_marketMakingSetCurve_onlyBundler() public {
        vm.prank(user);
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        adapter.marketMakingSetCurve(address(policy), TENOR_MARKET_ID, _points());
    }

    function test_marketMakingClearCurve_clearsInitiatorCurve() public {
        vm.prank(user);
        bundler3.multicall(_setCurveCall(TENOR_MARKET_ID, _points()));

        vm.prank(user);
        bundler3.multicall(_clearCurveCall(TENOR_MARKET_ID));

        _assertNoCurve(policy, user, TENOR_MARKET_ID);
    }

    function test_marketMakingClearCurve_pinsOnBehalfToInitiator() public {
        address attacker = makeAddr("Attacker");

        vm.prank(user);
        bundler3.multicall(_setCurveCall(TENOR_MARKET_ID, _points()));

        vm.prank(attacker);
        midnight.setIsAuthorized(address(adapter), true, attacker);

        vm.prank(attacker);
        bundler3.multicall(_clearCurveCall(TENOR_MARKET_ID));

        (uint32 victimTtm,,) = policy.curves(user, TENOR_MARKET_ID, 0);
        assertEq(victimTtm, _points()[0].ttm, "victim curve not cleared by another initiator");
    }

    function test_marketMakingClearCurve_emitsEvent() public {
        vm.prank(user);
        bundler3.multicall(_setCurveCall(TENOR_MARKET_ID, _points()));

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(policy));
        emit IMarketMakingPolicy.CurveCleared(user, TENOR_MARKET_ID);
        bundler3.multicall(_clearCurveCall(TENOR_MARKET_ID));
    }

    function test_marketMakingClearCurve_unauthorizedInitiator_policyReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(IMarketMakingPolicy.Unauthorized.selector);
        bundler3.multicall(_clearCurveCall(TENOR_MARKET_ID));
    }

    function test_marketMakingClearCurve_onlyBundler() public {
        vm.prank(user);
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        adapter.marketMakingClearCurve(address(policy), TENOR_MARKET_ID);
    }

    function testFuzz_marketMakingSetAndClearCurve(bytes32 tenorMarketId) public {
        vm.prank(user);
        bundler3.multicall(_setCurveCall(tenorMarketId, _points()));

        (uint32 ttm,,) = policy.curves(user, tenorMarketId, 0);
        assertEq(ttm, _points()[0].ttm);

        vm.prank(user);
        bundler3.multicall(_clearCurveCall(tenorMarketId));

        _assertNoCurve(policy, user, tenorMarketId);
    }
}

contract MarketMakingPolicyAdapterTest is MarketMakingPolicyAdapterTestBase {
    function _deployPolicy() internal override returns (IMarketMakingPolicy) {
        return new MarketMakingPolicy(address(midnight));
    }
}

contract MarketMakingPolicyAdapterPausableTest is MarketMakingPolicyAdapterTestBase {
    function _deployPolicy() internal override returns (IMarketMakingPolicy) {
        PausableMarketMakingPolicy pausable = new PausableMarketMakingPolicy(address(this), address(midnight));
        pausable.setPauser(address(this), true);
        return pausable;
    }

    function test_marketMakingSetCurve_whilePaused() public {
        PausableMarketMakingPolicy(address(policy)).pause();

        vm.prank(user);
        bundler3.multicall(_setCurveCall(TENOR_MARKET_ID, _points()));

        (uint32 ttm,,) = policy.curves(user, TENOR_MARKET_ID, 0);
        assertEq(ttm, _points()[0].ttm);
    }
}
