// MidnightWithdrawableCallback: many-market take scene.
// Standalone from callbacks_setup.spec: its setupCallbackEnv assumes the callback is never the offer maker nor a
// tracked position user, while this callback is the maker and transiently holds the buyer's credit.

import "../../midnight/specs/midnight_valid_state_many.spec";
import "../../safe_erc20.spec";

using MidnightWithdrawableCallbackHarness as _Callback;

methods {
    function _.onBuy(bytes32, MidnightHarness.Market, uint256, uint256, uint256, address, bytes) external
        => DISPATCHER(true);
    function _.withdraw(MidnightHarness.Market market, uint256 units, address onBehalf, address receiver) external
        => DISPATCHER(true);
}

function withdrawableTakeSetup(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback) {

    setupValidStateManyMidnight(e);

    require(_Callback != _Midnight, "SAFE: callback and Midnight are distinct deployed addresses");
    require(e.msg.sender != _Callback && e.msg.sender != _Midnight,
        "SAFE: neither the callback nor Midnight ever calls take");
    require(taker != _Callback && taker != _Midnight,
        "SAFE: the taker is a real account (SelfTake, and the callback authorizes no one)");
    require(offer.market.loanToken != _Callback && offer.market.loanToken != _Midnight,
        "SAFE: the loan token is a distinct deployed contract");

    // The callback is the take's buyer: position hooks prune untracked users, so it must be tracked.
    require(ghostMiPositionUserOne == _Callback,
        "SAFE: the callback (buyer) is a tracked position user");

    // take requires isAuthorized[maker][ratifier]; the callback's only setIsAuthorized call (constructor) authorizes
    // itself, so its offers are always ratified by itself.
    require(offer.ratifier == _Callback,
        "TRUSTED: the callback's only setIsAuthorized call (constructor) authorizes itself");
    // ratifier.spec ghosts isRatified out of take, so the offer shape it enforces is assumed here.
    require(offer.maker == _Callback && offer.callback == _Callback && offer.buy,
        "PROVED: MWC-01 isRatifiedOnlyAcceptsOwnParBuyOffer");
    require(to_mathint(offer.tick) == MAX_TICK_CVL(), "PROVED: MWC-01 isRatifiedOnlyAcceptsOwnParBuyOffer");
    require(ghostNumTicks == 5 && ghostTickFive == offer.tick,
        "SAFE: par tick = top tick ghostTickFive -- the tick axioms force ghostTickOne..Four below it");
    require(to_mathint(tickToPriceGhost(offer.tick)) == WAD_MATH(), "PROVED: MWC-05 parTickPriceIsWad");
    require(ghostMiIsAuthorized[_Callback][_Callback], "TRUSTED: constructor self-authorization");

    require(takerCallback == 0, "SCOPE: no taker callback (an unresolved onSell would havoc the scene)");

    // Pre-state proved preserved by MWC-06 / MWC-07 from the zero initial state. The induction step covers take
    // only: every other Midnight write to the callback's position needs its authorization (only itself) or existing
    // debt (always zero), and only the callback's own forceApprove changes its allowances.
    require(forall bytes32 id.
        ghostMiPositionCredit128[id][_Callback] == 0
        && ghostMiPositionPendingFee128[id][_Callback] == 0
        && ghostMiPositionDebt128[id][_Callback] == 0,
        "PROVED: MWC-06 callbackPositionStaysZero (inductive)");
    // Midnight's standing approval is left unconstrained: any value over-approximates 0, max, and a max being spent.
    require(forall address token. forall address spender.
        spender != _Midnight => ghostERC20Allowances256[token][_Callback][spender] == 0,
        "PROVED: MWC-07 callbackOnlyApprovesMidnight (inductive)");
}
