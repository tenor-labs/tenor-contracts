// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TenorAdapter} from "../../src/bundler/TenorAdapter.sol";
import {IMidnightAdapter} from "../../src/bundler/interfaces/IMidnightAdapter.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {IMidnight, Market, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {ErrorsLib} from "@bundler3/libraries/ErrorsLib.sol";
import {IBundler3} from "@bundler3/interfaces/IBundler3.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Fixtures} from "../helpers/Fixtures.sol";

/// @title MidnightAdapterCallbackGuardTest
/// @notice The take hooks (`onBuy`/`onSell`) and `onRepay` are not implemented on the adapter — a
///         take or repay naming it as callback reverts (no function). `onFlashLoan` is the only
///         reentering hook; it guards on `msg.sender == MIDNIGHT` and `caller == address(this)`, so
///         only a flash loan the adapter itself originated can reenter the bundler.
contract MidnightAdapterCallbackGuardTest is Fixtures {
    TenorAdapter internal adapter;
    Midnight internal midnight;
    IBundler3 internal bundler3;

    address internal user;
    address internal attacker;

    Market internal emptyMarket;

    function setUp() public {
        user = makeAddr("User");
        attacker = makeAddr("Attacker");

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        bundler3 = deployBundler3();
        adapter = new TenorAdapter(address(bundler3), address(midnight), makeAddr("Ratifier"));

        CollateralParams[] memory collaterals = new CollateralParams[](0);
        emptyMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(0),
            collateralParams: collaterals,
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    /* ═══════ forceApprove: max-allowance pattern ═══════ */

    /// @dev `midnightFlashLoan` sets max allowance before invoking flashLoan so Midnight's
    ///      post-callback `safeTransferFrom` pull survives any nested same-token action.
    function test_midnightFlashLoan_forceApprovesMidnightToMax() public {
        MockERC20 token = new MockERC20("Token", "TK", 18);
        uint256 assets = 100e18;

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = assets;

        vm.mockCall(
            address(midnight),
            abi.encodeWithSelector(IMidnight.flashLoan.selector, tokens, amounts, address(adapter), bytes("")),
            ""
        );

        assertEq(token.allowance(address(adapter), address(midnight)), 0, "precondition: no allowance");

        vm.prank(address(bundler3));
        adapter.midnightFlashLoan(tokens, amounts, "");

        assertEq(token.allowance(address(adapter), address(midnight)), type(uint256).max, "post: allowance set to max");
    }

    function test_midnightFlashLoan_mismatchedLengths_reverts() public {
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;

        vm.prank(address(bundler3));
        vm.expectRevert(IMidnightAdapter.InconsistentInput.selector);
        adapter.midnightFlashLoan(tokens, amounts, "");
    }

    function test_midnightFlashLoan_zeroAmount_reverts() public {
        MockERC20 token = new MockERC20("Token", "TK", 18);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);

        vm.prank(address(bundler3));
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        adapter.midnightFlashLoan(tokens, amounts, "");
    }

    /* ═══════ onFlashLoan guards ═══════ */

    function test_onFlashLoan_revertsUnauthorizedSender() public {
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        adapter.onFlashLoan(address(adapter), new address[](0), new uint256[](0), "");
    }

    function test_onFlashLoan_revertsWhenCallerIsNotAdapter() public {
        vm.mockCall(address(bundler3), abi.encodeWithSelector(IBundler3.initiator.selector), abi.encode(user));

        vm.prank(address(midnight));
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        adapter.onFlashLoan(attacker, new address[](0), new uint256[](0), "");
    }

    function test_onFlashLoan_succeedsWhenCallerIsAdapter() public {
        vm.mockCall(address(bundler3), abi.encodeWithSelector(IBundler3.reenter.selector), "");

        vm.prank(address(midnight));
        adapter.onFlashLoan(address(adapter), new address[](0), new uint256[](0), "");
    }

    function testFuzz_onFlashLoan_revertsWhenCallerIsNotAdapter(address _caller) public {
        vm.assume(_caller != address(adapter));

        vm.prank(address(midnight));
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        adapter.onFlashLoan(_caller, new address[](0), new uint256[](0), "");
    }
}
