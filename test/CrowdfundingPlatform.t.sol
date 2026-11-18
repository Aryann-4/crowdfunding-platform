// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CrowdfundingPlatform} from "../src/CrowdfundingPlatform.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @dev Contract used to verify that reentrancy through an ETH receiver cannot
 *      drain a campaign. The receive hook attempts to call `refund` again while
 *      the outer refund is still executing.
 */
contract ReentrantRefunder {
    CrowdfundingPlatform private immutable platform;
    uint256 public campaignId;
    uint256 public reentryAttempts;
    bool private inReceive;

    constructor(CrowdfundingPlatform _platform) {
        platform = _platform;
    }

    function pledge(uint256 _id) external payable {
        campaignId = _id;
        platform.pledge{value: msg.value}(_id, msg.value);
    }

    function attack(uint256 _id) external {
        campaignId = _id;
        platform.refund(_id);
    }

    receive() external payable {
        if (!inReceive) {
            inReceive = true;
            ++reentryAttempts;
            try platform.refund(campaignId) {} catch {}
            inReceive = false;
        }
    }
}

contract CrowdfundingPlatformTest is Test {
    CrowdfundingPlatform internal platform;
    MockERC20 internal token;

    address internal owner = address(this);
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal feeRecipient = makeAddr("feeRecipient");

    uint64 internal start;
    uint64 internal end;

    event CampaignLaunched(
        uint256 indexed id, address indexed creator, address indexed token, uint256 goal, uint64 startAt, uint64 endAt
    );
    event CampaignCanceled(uint256 indexed id, address indexed creator);
    event Pledged(uint256 indexed id, address indexed backer, uint256 amount);
    event Unpledged(uint256 indexed id, address indexed backer, uint256 amount);
    event Claimed(uint256 indexed id, address indexed creator, uint256 creatorAmount, uint256 feeAmount);
    event Refunded(uint256 indexed id, address indexed backer, uint256 amount);
    event PlatformFeeUpdated(uint256 previousFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address previousRecipient, address newRecipient);

    function setUp() public {
        vm.warp(1_700_000_000);

        platform = new CrowdfundingPlatform(owner, feeRecipient, 0);
        token = new MockERC20("Mock Token", "MOCK", 18);

        start = uint64(block.timestamp + 1 days);
        end = uint64(block.timestamp + 8 days);

        vm.deal(creator, 1_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);

        token.mint(alice, 1_000_000e18);
        token.mint(bob, 1_000_000e18);

        vm.prank(alice);
        token.approve(address(platform), type(uint256).max);
        vm.prank(bob);
        token.approve(address(platform), type(uint256).max);
    }

    /* ---------------------------------------------------------------------- */
    /*                               Helpers                                  */
    /* ---------------------------------------------------------------------- */

    function _launchETH(uint256 goal) internal returns (uint256 id) {
        vm.prank(creator);
        id = platform.launch(address(0), goal, start, end);
    }

    function _launchToken(uint256 goal) internal returns (uint256 id) {
        vm.prank(creator);
        id = platform.launch(address(token), goal, start, end);
    }

    function _pledgeETH(uint256 id, address backer, uint256 amount) internal {
        vm.prank(backer);
        platform.pledge{value: amount}(id, amount);
    }

    function _pledgeToken(uint256 id, address backer, uint256 amount) internal {
        vm.prank(backer);
        platform.pledge(id, amount);
    }

    /* ---------------------------------------------------------------------- */
    /*                                Launch                                  */
    /* ---------------------------------------------------------------------- */

    function test_LaunchETHCampaign() public {
        vm.expectEmit(true, true, true, true, address(platform));
        emit CampaignLaunched(0, creator, address(0), 10 ether, start, end);

        vm.prank(creator);
        uint256 id = platform.launch(address(0), 10 ether, start, end);

        assertEq(id, 0);
        assertEq(platform.campaignCount(), 1);

        CrowdfundingPlatform.Campaign memory campaign = platform.getCampaign(id);
        assertEq(campaign.creator, creator);
        assertEq(campaign.token, address(0));
        assertEq(campaign.goal, 10 ether);
        assertEq(campaign.pledged, 0);
        assertEq(campaign.startAt, start);
        assertEq(campaign.endAt, end);
        assertFalse(campaign.claimed);
        assertFalse(campaign.canceled);
    }

    function test_LaunchERC20Campaign() public {
        vm.expectEmit(true, true, true, true, address(platform));
        emit CampaignLaunched(0, creator, address(token), 50_000e18, start, end);

        vm.prank(creator);
        uint256 id = platform.launch(address(token), 50_000e18, start, end);

        CrowdfundingPlatform.Campaign memory campaign = platform.getCampaign(id);
        assertEq(campaign.token, address(token));
        assertEq(campaign.goal, 50_000e18);
        assertEq(platform.campaignCount(), 1);
    }

    function test_LaunchAtCurrentTimestamp() public {
        uint64 startNow = uint64(block.timestamp);
        uint64 endLater = uint64(block.timestamp + 1 days);

        vm.prank(creator);
        uint256 id = platform.launch(address(0), 1 ether, startNow, endLater);

        _pledgeETH(id, alice, 1 ether);
        assertEq(platform.getCampaign(id).pledged, 1 ether);
    }

    function test_LaunchAllowsExactlyNinetyDays() public {
        uint64 startLater = uint64(block.timestamp + 1 days);
        uint64 endLater = startLater + 90 days;

        vm.prank(creator);
        uint256 id = platform.launch(address(0), 1 ether, startLater, endLater);
        assertEq(platform.getCampaign(id).endAt, endLater);
    }

    function test_LaunchRevertsForPastStart() public {
        uint64 past = uint64(block.timestamp - 1);

        vm.expectRevert(CrowdfundingPlatform.InvalidStartTime.selector);
        vm.prank(creator);
        platform.launch(address(0), 1 ether, past, end);
    }

    function test_LaunchRevertsWhenEndEqualsStart() public {
        vm.expectRevert(CrowdfundingPlatform.InvalidEndTime.selector);
        vm.prank(creator);
        platform.launch(address(0), 1 ether, start, start);
    }

    function test_LaunchRevertsWhenEndBeforeStart() public {
        vm.expectRevert(CrowdfundingPlatform.InvalidEndTime.selector);
        vm.prank(creator);
        platform.launch(address(0), 1 ether, start, start - 1);
    }

    function test_LaunchRevertsWhenDurationExceedsNinetyDays() public {
        uint64 tooLate = start + 90 days + 1;

        vm.expectRevert(CrowdfundingPlatform.InvalidDuration.selector);
        vm.prank(creator);
        platform.launch(address(0), 1 ether, start, tooLate);
    }

    function test_LaunchRevertsForZeroGoal() public {
        vm.expectRevert(CrowdfundingPlatform.InvalidAmount.selector);
        vm.prank(creator);
        platform.launch(address(0), 0, start, end);
    }

    function test_LaunchRevertsForNonContractToken() public {
        address eoaToken = makeAddr("eoaToken");

        vm.expectRevert(CrowdfundingPlatform.InvalidToken.selector);
        vm.prank(creator);
        platform.launch(eoaToken, 1 ether, start, end);
    }

    /* ---------------------------------------------------------------------- */
    /*                                Cancel                                  */
    /* ---------------------------------------------------------------------- */

    function test_CancelBeforeStart() public {
        uint256 id = _launchETH(10 ether);

        vm.expectEmit(true, true, false, true, address(platform));
        emit CampaignCanceled(id, creator);

        vm.prank(creator);
        platform.cancel(id);

        assertTrue(platform.getCampaign(id).canceled);
    }

    function test_CancelRevertsIfNotCreator() public {
        uint256 id = _launchETH(10 ether);

        vm.expectRevert(CrowdfundingPlatform.NotCreator.selector);
        vm.prank(alice);
        platform.cancel(id);
    }

    function test_CancelRevertsAfterStart() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);

        vm.expectRevert(CrowdfundingPlatform.CampaignAlreadyStarted.selector);
        vm.prank(creator);
        platform.cancel(id);
    }

    function test_CancelRevertsWhenAlreadyCanceled() public {
        uint256 id = _launchETH(10 ether);

        vm.prank(creator);
        platform.cancel(id);

        vm.expectRevert(CrowdfundingPlatform.CampaignAlreadyCanceled.selector);
        vm.prank(creator);
        platform.cancel(id);
    }

    /* ---------------------------------------------------------------------- */
    /*                              Pledge ETH                                */
    /* ---------------------------------------------------------------------- */

    function test_PledgeETH() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);

        vm.expectEmit(true, true, false, true, address(platform));
        emit Pledged(id, alice, 1 ether);

        _pledgeETH(id, alice, 1 ether);

        assertEq(platform.pledgedAmount(id, alice), 1 ether);
        assertEq(platform.getCampaign(id).pledged, 1 ether);
        assertEq(address(platform).balance, 1 ether);
    }

    function test_PledgeETHAtDeadline() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(end);

        _pledgeETH(id, alice, 1 ether);
        assertEq(platform.pledgedAmount(id, alice), 1 ether);
    }

    function test_PledgeETHRevertsWithZeroValue() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);

        vm.expectRevert(CrowdfundingPlatform.InvalidAmount.selector);
        vm.prank(alice);
        platform.pledge{value: 0}(id, 0);
    }

    function test_PledgeETHRevertsOnAmountMismatch() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);

        vm.expectRevert(CrowdfundingPlatform.InvalidAmount.selector);
        vm.prank(alice);
        platform.pledge{value: 1 ether}(id, 2 ether);
    }

    function test_PledgeETHRevertsBeforeStart() public {
        uint256 id = _launchETH(10 ether);

        vm.expectRevert(CrowdfundingPlatform.CampaignNotActive.selector);
        _pledgeETH(id, alice, 1 ether);
    }

    function test_PledgeETHRevertsAfterEnd() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(end + 1);

        vm.expectRevert(CrowdfundingPlatform.CampaignNotActive.selector);
        _pledgeETH(id, alice, 1 ether);
    }

    function test_PledgeRevertsForCanceledCampaign() public {
        uint256 id = _launchETH(10 ether);
        vm.prank(creator);
        platform.cancel(id);
        vm.warp(start);

        vm.expectRevert(CrowdfundingPlatform.CampaignNotActive.selector);
        _pledgeETH(id, alice, 1 ether);
    }

    function test_PledgeRevertsForUnknownCampaign() public {
        vm.warp(start);

        vm.expectRevert(CrowdfundingPlatform.CampaignNotFound.selector);
        _pledgeETH(0, alice, 1 ether);
    }

    function test_PledgeAllowsOverfunding() public {
        uint256 id = _launchETH(1 ether);
        vm.warp(start);

        _pledgeETH(id, alice, 2 ether);

        assertEq(platform.getCampaign(id).pledged, 2 ether);
        assertEq(platform.getCampaign(id).goal, 1 ether);
    }

    /* ---------------------------------------------------------------------- */
    /*                             Pledge ERC-20                              */
    /* ---------------------------------------------------------------------- */

    function test_PledgeERC20() public {
        uint256 id = _launchToken(50_000e18);
        vm.warp(start);

        vm.expectEmit(true, true, false, true, address(platform));
        emit Pledged(id, alice, 10_000e18);

        _pledgeToken(id, alice, 10_000e18);

        assertEq(platform.pledgedAmount(id, alice), 10_000e18);
        assertEq(platform.getCampaign(id).pledged, 10_000e18);
        assertEq(token.balanceOf(address(platform)), 10_000e18);
        assertEq(token.balanceOf(alice), 990_000e18);
    }

    function test_PledgeERC20RevertsWithEthValue() public {
        uint256 id = _launchToken(50_000e18);
        vm.warp(start);

        vm.expectRevert(CrowdfundingPlatform.InvalidAmount.selector);
        vm.prank(alice);
        platform.pledge{value: 1 wei}(id, 10_000e18);
    }

    function test_PledgeERC20RevertsWithZeroAmount() public {
        uint256 id = _launchToken(50_000e18);
        vm.warp(start);

        vm.expectRevert(CrowdfundingPlatform.InvalidAmount.selector);
        vm.prank(alice);
        platform.pledge(id, 0);
    }

    function test_PledgeERC20RevertsWithoutAllowance() public {
        uint256 id = _launchToken(50_000e18);
        vm.warp(start);

        vm.prank(bob);
        token.approve(address(platform), 0);

        vm.expectRevert();
        vm.prank(bob);
        platform.pledge(id, 1e18);
    }

    /* ---------------------------------------------------------------------- */
    /*                               Unpledge                                 */
    /* ---------------------------------------------------------------------- */

    function test_UnpledgeETHPartial() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 2 ether);

        uint256 balanceBefore = alice.balance;

        vm.expectEmit(true, true, false, true, address(platform));
        emit Unpledged(id, alice, 0.5 ether);

        vm.prank(alice);
        platform.unpledge(id, 0.5 ether);

        assertEq(platform.pledgedAmount(id, alice), 1.5 ether);
        assertEq(platform.getCampaign(id).pledged, 1.5 ether);
        assertEq(alice.balance, balanceBefore + 0.5 ether);
        assertEq(address(platform).balance, 1.5 ether);
    }

    function test_UnpledgeETHFull() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 2 ether);

        vm.prank(alice);
        platform.unpledge(id, 2 ether);

        assertEq(platform.pledgedAmount(id, alice), 0);
        assertEq(platform.getCampaign(id).pledged, 0);
        assertEq(address(platform).balance, 0);
    }

    function test_UnpledgeERC20() public {
        uint256 id = _launchToken(50_000e18);
        vm.warp(start);
        _pledgeToken(id, alice, 10_000e18);

        vm.prank(alice);
        platform.unpledge(id, 4_000e18);

        assertEq(platform.pledgedAmount(id, alice), 6_000e18);
        assertEq(token.balanceOf(alice), 994_000e18);
        assertEq(token.balanceOf(address(platform)), 6_000e18);
    }

    function test_UnpledgeRevertsAfterEnd() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 1 ether);
        vm.warp(end);

        vm.expectRevert(CrowdfundingPlatform.CampaignNotActive.selector);
        vm.prank(alice);
        platform.unpledge(id, 1 ether);
    }

    function test_UnpledgeRevertsForMoreThanBalance() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 1 ether);

        vm.expectRevert(CrowdfundingPlatform.InvalidAmount.selector);
        vm.prank(alice);
        platform.unpledge(id, 2 ether);
    }

    function test_UnpledgeRevertsWithZeroAmount() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 1 ether);

        vm.expectRevert(CrowdfundingPlatform.InvalidAmount.selector);
        vm.prank(alice);
        platform.unpledge(id, 0);
    }

    function test_UnpledgeRevertsWithoutPledge() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);

        vm.expectRevert(CrowdfundingPlatform.InvalidAmount.selector);
        vm.prank(alice);
        platform.unpledge(id, 1 ether);
    }

    /* ---------------------------------------------------------------------- */
    /*                                 Claim                                  */
    /* ---------------------------------------------------------------------- */

    function test_ClaimETH() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 10 ether);
        vm.warp(end + 1);

        uint256 balanceBefore = creator.balance;

        vm.expectEmit(true, true, false, true, address(platform));
        emit Claimed(id, creator, 10 ether, 0);

        vm.prank(creator);
        platform.claim(id);

        assertEq(creator.balance, balanceBefore + 10 ether);
        assertTrue(platform.getCampaign(id).claimed);
        assertEq(address(platform).balance, 0);
    }

    function test_ClaimETHWithPlatformFee() public {
        platform.setPlatformFee(250); // 2.5%

        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 10 ether);
        vm.warp(end + 1);

        uint256 creatorBefore = creator.balance;
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(creator);
        platform.claim(id);

        assertEq(creator.balance, creatorBefore + 9.75 ether);
        assertEq(feeRecipient.balance, feeBefore + 0.25 ether);
        assertEq(address(platform).balance, 0);
    }

    function test_ClaimERC20() public {
        uint256 id = _launchToken(50_000e18);
        vm.warp(start);
        _pledgeToken(id, alice, 50_000e18);
        vm.warp(end + 1);

        vm.prank(creator);
        platform.claim(id);

        assertEq(token.balanceOf(creator), 50_000e18);
        assertEq(token.balanceOf(address(platform)), 0);
        assertTrue(platform.getCampaign(id).claimed);
    }

    function test_ClaimERC20WithPlatformFee() public {
        platform.setPlatformFee(500); // 5%

        uint256 id = _launchToken(50_000e18);
        vm.warp(start);
        _pledgeToken(id, alice, 50_000e18);
        vm.warp(end + 1);

        vm.prank(creator);
        platform.claim(id);

        assertEq(token.balanceOf(creator), 47_500e18);
        assertEq(token.balanceOf(feeRecipient), 2_500e18);
    }

    function test_ClaimOverfundedCampaign() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 12 ether);
        vm.warp(end + 1);

        uint256 balanceBefore = creator.balance;

        vm.prank(creator);
        platform.claim(id);

        assertEq(creator.balance, balanceBefore + 12 ether);
    }

    function test_ClaimRevertsIfNotCreator() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 10 ether);
        vm.warp(end + 1);

        vm.expectRevert(CrowdfundingPlatform.NotCreator.selector);
        vm.prank(alice);
        platform.claim(id);
    }

    function test_ClaimRevertsBeforeEnd() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 10 ether);
        vm.warp(end);

        vm.expectRevert(CrowdfundingPlatform.CampaignStillActive.selector);
        vm.prank(creator);
        platform.claim(id);
    }

    function test_ClaimRevertsIfGoalNotReached() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 5 ether);
        vm.warp(end + 1);

        vm.expectRevert(CrowdfundingPlatform.GoalNotReached.selector);
        vm.prank(creator);
        platform.claim(id);
    }

    function test_ClaimRevertsOnDoubleClaim() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 10 ether);
        vm.warp(end + 1);

        vm.prank(creator);
        platform.claim(id);

        vm.expectRevert(CrowdfundingPlatform.AlreadyClaimed.selector);
        vm.prank(creator);
        platform.claim(id);
    }

    /* ---------------------------------------------------------------------- */
    /*                                Refund                                  */
    /* ---------------------------------------------------------------------- */

    function test_RefundETHAfterFailedCampaign() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 1 ether);
        vm.warp(end + 1);

        uint256 balanceBefore = alice.balance;

        vm.expectEmit(true, true, false, true, address(platform));
        emit Refunded(id, alice, 1 ether);

        vm.prank(alice);
        platform.refund(id);

        assertEq(alice.balance, balanceBefore + 1 ether);
        assertEq(platform.pledgedAmount(id, alice), 0);
        assertEq(platform.getCampaign(id).pledged, 0);
        assertEq(address(platform).balance, 0);
    }

    function test_RefundERC20AfterFailedCampaign() public {
        uint256 id = _launchToken(50_000e18);
        vm.warp(start);
        _pledgeToken(id, alice, 10_000e18);
        vm.warp(end + 1);

        vm.prank(alice);
        platform.refund(id);

        assertEq(token.balanceOf(alice), 1_000_000e18);
        assertEq(token.balanceOf(address(platform)), 0);
        assertEq(platform.pledgedAmount(id, alice), 0);
    }

    function test_MultipleBackersCanRefund() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 1 ether);
        _pledgeETH(id, bob, 2 ether);
        vm.warp(end + 1);

        vm.prank(alice);
        platform.refund(id);
        vm.prank(bob);
        platform.refund(id);

        assertEq(platform.getCampaign(id).pledged, 0);
        assertEq(address(platform).balance, 0);
    }

    function test_RefundAfterPartialUnpledge() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 2 ether);

        vm.prank(alice);
        platform.unpledge(id, 0.5 ether);

        uint256 balanceBefore = alice.balance;
        vm.warp(end + 1);

        vm.prank(alice);
        platform.refund(id);

        assertEq(alice.balance, balanceBefore + 1.5 ether);
        assertEq(address(platform).balance, 0);
    }

    function test_RefundRevertsBeforeDeadline() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 1 ether);
        vm.warp(end);

        vm.expectRevert(CrowdfundingPlatform.CampaignStillActive.selector);
        vm.prank(alice);
        platform.refund(id);
    }

    function test_RefundRevertsWhenGoalReached() public {
        uint256 id = _launchETH(2 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 2 ether);
        vm.warp(end + 1);

        vm.expectRevert(CrowdfundingPlatform.GoalAlreadyReached.selector);
        vm.prank(alice);
        platform.refund(id);
    }

    function test_RefundRevertsOnDoubleRefund() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(start);
        _pledgeETH(id, alice, 1 ether);
        vm.warp(end + 1);

        vm.prank(alice);
        platform.refund(id);

        vm.expectRevert(CrowdfundingPlatform.InvalidAmount.selector);
        vm.prank(alice);
        platform.refund(id);
    }

    function test_RefundRevertsWithoutPledge() public {
        uint256 id = _launchETH(10 ether);
        vm.warp(end + 1);

        vm.expectRevert(CrowdfundingPlatform.InvalidAmount.selector);
        vm.prank(alice);
        platform.refund(id);
    }

    /* ---------------------------------------------------------------------- */
    /*                         Security / Configuration                       */
    /* ---------------------------------------------------------------------- */

    function test_DirectETHTransferReverts() public {
        vm.deal(address(this), 1 ether);

        (bool success,) = address(platform).call{value: 1 ether}("");
        assertFalse(success);
        assertEq(address(platform).balance, 0);
    }

    function test_UnknownCalldataReverts() public {
        (bool success,) = address(platform).call(hex"deadbeef");
        assertFalse(success);
        assertEq(address(platform).balance, 0);
    }

    function test_RefundReentrancyIsBlocked() public {
        uint256 id = _launchETH(10 ether);
        ReentrantRefunder attacker = new ReentrantRefunder(platform);

        vm.deal(address(this), 1 ether);
        vm.warp(start);
        attacker.pledge{value: 1 ether}(id);

        vm.warp(end + 1);
        attacker.attack(id);

        assertEq(address(attacker).balance, 1 ether);
        assertEq(attacker.reentryAttempts(), 1);
        assertEq(platform.pledgedAmount(id, address(attacker)), 0);
        assertEq(address(platform).balance, 0);
    }

    function test_SetPlatformFee() public {
        vm.expectEmit(false, false, false, true, address(platform));
        emit PlatformFeeUpdated(0, 100);

        platform.setPlatformFee(100);
        assertEq(platform.platformFeeBps(), 100);
    }

    function test_SetPlatformFeeRevertsAboveMax() public {
        vm.expectRevert(CrowdfundingPlatform.InvalidFeeBps.selector);
        platform.setPlatformFee(501);
    }

    function test_SetPlatformFeeRevertsIfNotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        platform.setPlatformFee(100);
    }

    function test_SetFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");

        vm.expectEmit(false, false, false, true, address(platform));
        emit FeeRecipientUpdated(feeRecipient, newRecipient);

        platform.setFeeRecipient(newRecipient);
        assertEq(platform.feeRecipient(), newRecipient);
    }

    function test_SetFeeRecipientRevertsForZeroAddress() public {
        vm.expectRevert(CrowdfundingPlatform.InvalidFeeRecipient.selector);
        platform.setFeeRecipient(address(0));
    }

    function test_ConstructorRevertsForFeeAboveMax() public {
        vm.expectRevert(CrowdfundingPlatform.InvalidFeeBps.selector);
        new CrowdfundingPlatform(owner, feeRecipient, 501);
    }

    function test_ConstructorRevertsForZeroFeeRecipient() public {
        vm.expectRevert(CrowdfundingPlatform.InvalidFeeRecipient.selector);
        new CrowdfundingPlatform(owner, address(0), 0);
    }

    /* ---------------------------------------------------------------------- */
    /*                                 Fuzz                                   */
    /* ---------------------------------------------------------------------- */

    function testFuzz_PledgeETH(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 100 ether);
        uint256 id = _launchETH(1_000 ether);
        vm.warp(start);

        _pledgeETH(id, alice, amount);

        assertEq(platform.pledgedAmount(id, alice), amount);
        assertEq(platform.getCampaign(id).pledged, amount);
        assertEq(address(platform).balance, amount);
    }

    function testFuzz_PledgeAndRefundETH(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 100 ether);
        uint256 id = _launchETH(1_000 ether);
        vm.warp(start);

        _pledgeETH(id, alice, amount);
        uint256 balanceBefore = alice.balance;

        vm.warp(end + 1);
        vm.prank(alice);
        platform.refund(id);

        assertEq(alice.balance, balanceBefore + amount);
        assertEq(platform.pledgedAmount(id, alice), 0);
        assertEq(address(platform).balance, 0);
    }

    function testFuzz_PledgeAndRefundERC20(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 100_000e18);
        uint256 id = _launchToken(1_000_000e18);
        vm.warp(start);

        _pledgeToken(id, alice, amount);
        assertEq(platform.pledgedAmount(id, alice), amount);

        vm.warp(end + 1);
        vm.prank(alice);
        platform.refund(id);

        assertEq(token.balanceOf(alice), 1_000_000e18);
        assertEq(token.balanceOf(address(platform)), 0);
    }

    function testFuzz_UnpledgeETH(uint96 rawAmount, uint96 rawWithdraw) public {
        uint256 amount = bound(uint256(rawAmount), 1, 100 ether);
        uint256 withdraw = bound(uint256(rawWithdraw), 1, amount);
        uint256 id = _launchETH(1_000 ether);
        vm.warp(start);

        _pledgeETH(id, alice, amount);
        vm.prank(alice);
        platform.unpledge(id, withdraw);

        assertEq(platform.pledgedAmount(id, alice), amount - withdraw);
        assertEq(platform.getCampaign(id).pledged, amount - withdraw);
        assertEq(address(platform).balance, amount - withdraw);
    }
}
