// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CrowdfundingPlatform
 * @author Crowdfunding Platform Team
 * @notice A decentralized crowdfunding platform supporting native ETH and ERC-20
 *         campaigns. Creators can launch time-bounded campaigns, backers can pledge
 *         and withdraw while a campaign is live, and funds are settled after the
 *         deadline using a pull-payment model.
 * @dev Security model:
 *      - All value-moving functions are protected by OpenZeppelin's
 *        {ReentrancyGuard}.
 *      - All external interactions happen after state updates (CEI).
 *      - ETH is sent with low-level calls and checked for success.
 *      - ERC-20 transfers use {SafeERC20}.
 *      - The contract rejects unsolicited ETH transfers.
 */
contract CrowdfundingPlatform is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Maximum campaign duration allowed by the platform (90 days).
    uint256 public constant MAX_CAMPAIGN_DURATION = 90 days;

    /// @notice Maximum platform fee, expressed in basis points (5%).
    uint256 public constant MAX_FEE_BPS = 500;

    /// @notice Denominator used for basis-point calculations.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /**
     * @notice Stores the configuration and accounting state of a campaign.
     * @param creator Wallet address of the campaign creator.
     * @param token Accepted ERC-20 token, or `address(0)` for native ETH.
     * @param goal Funding target in wei or token smallest units.
     * @param pledged Total amount currently pledged.
     * @param startAt Timestamp at which pledging becomes possible.
     * @param endAt Timestamp after which pledging stops and settlement begins.
     * @param claimed True once the creator has withdrawn a successful campaign.
     * @param canceled True if the creator canceled before the campaign started.
     */
    struct Campaign {
        address creator;
        address token;
        uint256 goal;
        uint256 pledged;
        uint64 startAt;
        uint64 endAt;
        bool claimed;
        bool canceled;
    }

    /// @notice Total number of campaigns launched. Campaign IDs start at zero.
    uint256 public campaignCount;

    /// @notice Campaign data indexed by campaign ID.
    mapping(uint256 => Campaign) public campaigns;

    /// @notice Amount pledged by each backer for each campaign.
    mapping(uint256 => mapping(address => uint256)) public pledgedAmount;

    /// @notice Platform fee charged on successfully claimed campaigns, in basis points.
    uint256 public platformFeeBps;

    /// @notice Recipient of the platform fee.
    address public feeRecipient;

    /// @notice Emitted when a new campaign is launched.
    event CampaignLaunched(
        uint256 indexed id, address indexed creator, address indexed token, uint256 goal, uint64 startAt, uint64 endAt
    );

    /// @notice Emitted when a creator cancels a campaign before it starts.
    event CampaignCanceled(uint256 indexed id, address indexed creator);

    /// @notice Emitted when a backer pledges funds to a campaign.
    event Pledged(uint256 indexed id, address indexed backer, uint256 amount);

    /// @notice Emitted when a backer withdraws pledged funds from a live campaign.
    event Unpledged(uint256 indexed id, address indexed backer, uint256 amount);

    /// @notice Emitted when a creator claims funds from a successful campaign.
    event Claimed(uint256 indexed id, address indexed creator, uint256 creatorAmount, uint256 feeAmount);

    /// @notice Emitted when a backer claims a refund from a failed campaign.
    event Refunded(uint256 indexed id, address indexed backer, uint256 amount);

    /// @notice Emitted when the platform fee is updated.
    event PlatformFeeUpdated(uint256 previousFeeBps, uint256 newFeeBps);

    /// @notice Emitted when the fee recipient is updated.
    event FeeRecipientUpdated(address previousRecipient, address newRecipient);

    /// @notice Thrown when interacting with a campaign ID that does not exist.
    error CampaignNotFound();

    /// @notice Thrown when the caller is not the campaign creator.
    error NotCreator();

    /// @notice Thrown when a campaign cannot be canceled because it has started.
    error CampaignAlreadyStarted();

    /// @notice Thrown when a campaign is already canceled.
    error CampaignAlreadyCanceled();

    /// @notice Thrown when an operation requires an active campaign but it is not active.
    error CampaignNotActive();

    /// @notice Thrown when an operation requires the campaign deadline to have passed.
    error CampaignStillActive();

    /// @notice Thrown when a successful campaign's goal has not been reached.
    error GoalNotReached();

    /// @notice Thrown when a failed campaign's goal was reached, so refunds are unavailable.
    error GoalAlreadyReached();

    /// @notice Thrown when the creator has already claimed a successful campaign.
    error AlreadyClaimed();

    /// @notice Thrown for zero or otherwise invalid amounts.
    error InvalidAmount();

    /// @notice Thrown when the start timestamp is in the past or otherwise invalid.
    error InvalidStartTime();

    /// @notice Thrown when the end timestamp is not after the start timestamp.
    error InvalidEndTime();

    /// @notice Thrown when the campaign duration exceeds the maximum.
    error InvalidDuration();

    /// @notice Thrown when the supplied ERC-20 token address is not a contract.
    error InvalidToken();

    /// @notice Thrown when the configured fee exceeds {MAX_FEE_BPS}.
    error InvalidFeeBps();

    /// @notice Thrown when the fee recipient is the zero address.
    error InvalidFeeRecipient();

    /// @notice Thrown when a native ETH transfer fails.
    error TransferFailed();

    /// @notice Thrown when ETH is sent directly to the contract outside a pledge.
    error DirectEthTransferNotAllowed();

    /**
     * @notice Deploys the platform.
     * @param initialOwner Owner allowed to update platform configuration.
     * @param initialFeeRecipient Recipient of platform fees.
     * @param initialPlatformFeeBps Initial fee in basis points (max {MAX_FEE_BPS}).
     */
    constructor(address initialOwner, address initialFeeRecipient, uint256 initialPlatformFeeBps)
        Ownable(initialOwner)
    {
        if (initialPlatformFeeBps > MAX_FEE_BPS) revert InvalidFeeBps();
        if (initialFeeRecipient == address(0)) revert InvalidFeeRecipient();

        platformFeeBps = initialPlatformFeeBps;
        feeRecipient = initialFeeRecipient;

        emit PlatformFeeUpdated(0, initialPlatformFeeBps);
        emit FeeRecipientUpdated(address(0), initialFeeRecipient);
    }

    /**
     * @notice Launches a new campaign.
     * @dev `_token` must be `address(0)` for ETH or an ERC-20 contract address.
     *      The start time may equal the current block timestamp. Duration must be
     *      greater than zero and at most {MAX_CAMPAIGN_DURATION}.
     * @param _token Token accepted by the campaign (`address(0)` for ETH).
     * @param _goal Funding goal in wei or token smallest units.
     * @param _startAt Timestamp at which pledging starts.
     * @param _endAt Timestamp at which pledging ends.
     * @return id The newly created campaign ID.
     */
    function launch(address _token, uint256 _goal, uint64 _startAt, uint64 _endAt) external returns (uint256 id) {
        if (_goal == 0) revert InvalidAmount();
        if (_startAt < block.timestamp) revert InvalidStartTime();
        if (_endAt <= _startAt) revert InvalidEndTime();
        if (_endAt - _startAt > MAX_CAMPAIGN_DURATION) revert InvalidDuration();
        if (_token != address(0) && _token.code.length == 0) revert InvalidToken();

        id = campaignCount++;

        campaigns[id] = Campaign({
            creator: msg.sender,
            token: _token,
            goal: _goal,
            pledged: 0,
            startAt: _startAt,
            endAt: _endAt,
            claimed: false,
            canceled: false
        });

        emit CampaignLaunched(id, msg.sender, _token, _goal, _startAt, _endAt);
    }

    /**
     * @notice Cancels a campaign before it starts.
     * @dev Only the creator may cancel, and only while
     *      `block.timestamp < campaign.startAt`. No pledges can exist yet.
     * @param _id Campaign ID.
     */
    function cancel(uint256 _id) external {
        Campaign storage campaign = _getCampaign(_id);

        if (msg.sender != campaign.creator) revert NotCreator();
        if (campaign.canceled) revert CampaignAlreadyCanceled();
        if (block.timestamp >= campaign.startAt) revert CampaignAlreadyStarted();

        campaign.canceled = true;

        emit CampaignCanceled(_id, msg.sender);
    }

    /**
     * @notice Pledges funds to an active campaign.
     * @dev For ETH campaigns, `msg.value` must be non-zero and exactly equal
     *      `_amount`. For ERC-20 campaigns, `msg.value` must be zero and
     *      `_amount` tokens are pulled from the caller using {SafeERC20}.
     *      Overfunding is permitted; a campaign succeeds when
     *      `pledged >= goal`.
     * @param _id Campaign ID.
     * @param _amount Amount to pledge in wei or token smallest units.
     */
    function pledge(uint256 _id, uint256 _amount) external payable nonReentrant {
        Campaign storage campaign = _getCampaign(_id);
        _requireActive(campaign);

        if (campaign.token == address(0)) {
            if (msg.value == 0 || _amount != msg.value) revert InvalidAmount();
        } else {
            if (msg.value != 0 || _amount == 0) revert InvalidAmount();
            IERC20(campaign.token).safeTransferFrom(msg.sender, address(this), _amount);
        }

        campaign.pledged += _amount;
        pledgedAmount[_id][msg.sender] += _amount;

        emit Pledged(_id, msg.sender, _amount);
    }

    /**
     * @notice Withdraws part or all of a pledge from a live campaign.
     * @dev Only available before `endAt`. State is updated before the transfer.
     * @param _id Campaign ID.
     * @param _amount Amount to withdraw in wei or token smallest units.
     */
    function unpledge(uint256 _id, uint256 _amount) external nonReentrant {
        Campaign storage campaign = _getCampaign(_id);

        if (campaign.canceled || block.timestamp < campaign.startAt || block.timestamp >= campaign.endAt) {
            revert CampaignNotActive();
        }
        if (_amount == 0) revert InvalidAmount();

        uint256 balance = pledgedAmount[_id][msg.sender];
        if (_amount > balance) revert InvalidAmount();

        // Effects before interactions.
        unchecked {
            pledgedAmount[_id][msg.sender] = balance - _amount;
            campaign.pledged -= _amount;
        }

        emit Unpledged(_id, msg.sender, _amount);

        _payout(campaign.token, msg.sender, _amount);
    }

    /**
     * @notice Claims funds for a successful campaign after its deadline.
     * @dev The platform fee is deducted from the total pledged amount and sent
     *      to {feeRecipient}; the remainder is sent to the creator. The campaign
     *      is marked claimed before any transfer (CEI).
     * @param _id Campaign ID.
     */
    function claim(uint256 _id) external nonReentrant {
        Campaign storage campaign = _getCampaign(_id);

        if (msg.sender != campaign.creator) revert NotCreator();
        if (block.timestamp <= campaign.endAt) revert CampaignStillActive();
        if (campaign.claimed) revert AlreadyClaimed();
        if (campaign.pledged < campaign.goal) revert GoalNotReached();

        // Effects before interactions.
        campaign.claimed = true;

        uint256 total = campaign.pledged;
        uint256 fee = (total * platformFeeBps) / BPS_DENOMINATOR;
        uint256 creatorAmount = total - fee;

        emit Claimed(_id, campaign.creator, creatorAmount, fee);

        _payout(campaign.token, campaign.creator, creatorAmount);
        if (fee != 0) {
            _payout(campaign.token, feeRecipient, fee);
        }
    }

    /**
     * @notice Refunds a backer's full pledge from a failed campaign.
     * @dev Only available after `endAt` and only when `pledged < goal`. The
     *      backer's recorded balance is cleared before the transfer (CEI).
     *      Refunds are pull-based: each backer must claim individually.
     * @param _id Campaign ID.
     */
    function refund(uint256 _id) external nonReentrant {
        Campaign storage campaign = _getCampaign(_id);

        if (block.timestamp <= campaign.endAt) revert CampaignStillActive();
        if (campaign.pledged >= campaign.goal) revert GoalAlreadyReached();

        uint256 balance = pledgedAmount[_id][msg.sender];
        if (balance == 0) revert InvalidAmount();

        // Effects before interactions.
        pledgedAmount[_id][msg.sender] = 0;
        campaign.pledged -= balance;

        emit Refunded(_id, msg.sender, balance);

        _payout(campaign.token, msg.sender, balance);
    }

    /**
     * @notice Updates the platform fee.
     * @dev Only callable by the owner. Capped at {MAX_FEE_BPS}.
     * @param _newFeeBps New fee in basis points.
     */
    function setPlatformFee(uint256 _newFeeBps) external onlyOwner {
        if (_newFeeBps > MAX_FEE_BPS) revert InvalidFeeBps();

        uint256 previousFee = platformFeeBps;
        platformFeeBps = _newFeeBps;

        emit PlatformFeeUpdated(previousFee, _newFeeBps);
    }

    /**
     * @notice Updates the fee recipient.
     * @dev Only callable by the owner. The zero address is rejected.
     * @param _newFeeRecipient New fee recipient.
     */
    function setFeeRecipient(address _newFeeRecipient) external onlyOwner {
        if (_newFeeRecipient == address(0)) revert InvalidFeeRecipient();

        address previousRecipient = feeRecipient;
        feeRecipient = _newFeeRecipient;

        emit FeeRecipientUpdated(previousRecipient, _newFeeRecipient);
    }

    /**
     * @notice Returns full campaign details for a given ID.
     * @param _id Campaign ID.
     * @return campaign The campaign struct.
     */
    function getCampaign(uint256 _id) external view returns (Campaign memory campaign) {
        campaign = _getCampaign(_id);
    }

    /**
     * @notice Rejects direct ETH transfers. ETH may only enter via {pledge}.
     */
    receive() external payable {
        revert DirectEthTransferNotAllowed();
    }

    /**
     * @notice Rejects calls with unknown calldata, including direct ETH transfers.
     */
    fallback() external payable {
        revert DirectEthTransferNotAllowed();
    }

    /**
     * @dev Loads a campaign and reverts if it does not exist.
     * @param _id Campaign ID.
     * @return campaign Storage pointer to the campaign.
     */
    function _getCampaign(uint256 _id) private view returns (Campaign storage campaign) {
        if (_id >= campaignCount) revert CampaignNotFound();
        campaign = campaigns[_id];
    }

    /**
     * @dev Reverts unless the campaign is not canceled and the current timestamp
     *      falls within the inclusive pledge window.
     * @param campaign Campaign being checked.
     */
    function _requireActive(Campaign storage campaign) private view {
        if (campaign.canceled || block.timestamp < campaign.startAt || block.timestamp > campaign.endAt) {
            revert CampaignNotActive();
        }
    }

    /**
     * @dev Sends ETH or ERC-20 tokens to a recipient.
     * @param _token Token address, or `address(0)` for ETH.
     * @param _to Recipient.
     * @param _amount Amount to transfer.
     */
    function _payout(address _token, address _to, uint256 _amount) private {
        if (_amount == 0) return;

        if (_token == address(0)) {
            (bool success,) = payable(_to).call{value: _amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }
}
