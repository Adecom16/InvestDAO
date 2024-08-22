// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract DecentralizedFundraising is Ownable {
    using Address for address payable;

    IERC20 public token;
    uint256 public rate; // Number of tokens per Ether
    uint256 public tokensSold;
    uint256 public saleEnd;
    uint256 public goal; // Minimum fundraising goal in Ether
    uint256 public raisedAmount; // Total amount of Ether raised

    bool public goalReached;
    bool public saleEnded;
    bool public emergencyPaused;

    struct Tier {
        uint256 minContribution;
        uint256 maxContribution;
        uint256 bonus; // Percentage of bonus tokens
        uint256 vestingPeriod; // Time in seconds
    }

    Tier[] public tiers;

    mapping(address => uint256) public contributions;
    mapping(address => uint256) public claimedTokens;
    mapping(address => uint256) public vestedTokens;
    mapping(address => uint256) public vestingStartTime;
    mapping(address => bool) public whitelisted;

    event TokensPurchased(address indexed buyer, uint256 amount);
    event SaleEnded(address indexed owner, uint256 unsoldTokens, bool goalReached);
    event RefundIssued(address indexed investor, uint256 amount);
    event TierAdded(uint256 indexed tierIndex, uint256 minContribution, uint256 maxContribution, uint256 bonus, uint256 vestingPeriod);
    event TokensClaimed(address indexed investor, uint256 amount);
    event EmergencyPauseActivated();
    event EmergencyPauseDeactivated();

    constructor(
        IERC20 _token,
        uint256 _rate,
        uint256 _saleDuration,
        uint256 _goal,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_rate > 0, "Rate should be greater than 0");
        require(address(_token) != address(0), "Token address cannot be zero");

        token = _token;
        rate = _rate;
        saleEnd = block.timestamp + _saleDuration;
        goal = _goal;
    }

    modifier onlyWhitelisted() {
        require(whitelisted[msg.sender], "Not whitelisted");
        _;
    }

    modifier whenNotPaused() {
        require(!emergencyPaused, "Emergency pause is active");
        _;
    }

    receive() external payable onlyWhitelisted whenNotPaused {
        buyTokens();
    }

    function buyTokens() public payable onlyWhitelisted whenNotPaused {
        require(block.timestamp < saleEnd, "Token sale has ended");
        require(msg.value > 0, "Ether value must be greater than 0");

        uint256 tierIndex = getTier(msg.value);
        require(tierIndex < tiers.length, "No matching tier found");

        Tier memory tier = tiers[tierIndex];
        require(contributions[msg.sender] + msg.value <= tier.maxContribution, "Exceeds maximum contribution for this tier");

        uint256 tokenAmount = (msg.value * rate) * (100 + tier.bonus) / 100;
        require(token.balanceOf(address(this)) >= tokenAmount, "Not enough tokens available");

        contributions[msg.sender] += msg.value;
        raisedAmount += msg.value;
        tokensSold += tokenAmount;

        vestedTokens[msg.sender] += tokenAmount;
        if (vestingStartTime[msg.sender] == 0) {
            vestingStartTime[msg.sender] = block.timestamp;
        }

        emit TokensPurchased(msg.sender, tokenAmount);
    }

    function endSale() external onlyOwner {
        require(block.timestamp >= saleEnd, "Sale is still ongoing");
        require(!saleEnded, "Sale has already ended");

        goalReached = raisedAmount >= goal;
        saleEnded = true;

        if (goalReached) {
            uint256 unsoldTokens = token.balanceOf(address(this));
            if (unsoldTokens > 0) {
                token.transfer(owner(), unsoldTokens);
            }
            payable(owner()).sendValue(address(this).balance);
        } else {
            emit SaleEnded(owner(), 0, false);
        }

        emit SaleEnded(owner(), token.balanceOf(address(this)), goalReached);
    }

    function claimTokens() external whenNotPaused {
        require(saleEnded, "Sale has not ended");
        require(goalReached, "Fundraising goal not reached");
        require(contributions[msg.sender] > 0, "No contributions made");

        uint256 tokenAmount = calculateClaimableTokens(msg.sender);
        require(tokenAmount > 0, "No tokens available for claiming");

        vestedTokens[msg.sender] -= tokenAmount;
        claimedTokens[msg.sender] += tokenAmount;

        token.transfer(msg.sender, tokenAmount);
        emit TokensClaimed(msg.sender, tokenAmount);
    }

    function issueRefund() external whenNotPaused {
        require(saleEnded, "Sale has not ended");
        require(!goalReached, "Fundraising goal was reached");
        require(contributions[msg.sender] > 0, "No contributions made");

        uint256 refundAmount = contributions[msg.sender];
        contributions[msg.sender] = 0;

        payable(msg.sender).sendValue(refundAmount);
        emit RefundIssued(msg.sender, refundAmount);
    }

    function addTier(
        uint256 _minContribution,
        uint256 _maxContribution,
        uint256 _bonus,
        uint256 _vestingPeriod
    ) external onlyOwner {
        require(_maxContribution > _minContribution, "Max contribution should be greater than min contribution");
        tiers.push(Tier({
            minContribution: _minContribution,
            maxContribution: _maxContribution,
            bonus: _bonus,
            vestingPeriod: _vestingPeriod
        }));
        emit TierAdded(tiers.length - 1, _minContribution, _maxContribution, _bonus, _vestingPeriod);
    }

    function addWhitelist(address _investor) external onlyOwner {
        whitelisted[_investor] = true;
    }

    function removeWhitelist(address _investor) external onlyOwner {
        whitelisted[_investor] = false;
    }

    function withdrawFunds() external onlyOwner {
        require(goalReached, "Goal not reached, cannot withdraw funds");
        payable(owner()).sendValue(address(this).balance);
    }

    function activateEmergencyPause() external onlyOwner {
        emergencyPaused = true;
        emit EmergencyPauseActivated();
    }

    function deactivateEmergencyPause() external onlyOwner {
        emergencyPaused = false;
        emit EmergencyPauseDeactivated();
    }

    function calculateClaimableTokens(address _investor) internal view returns (uint256) {
        uint256 totalVested = vestedTokens[_investor];
        if (totalVested == 0 || vestingStartTime[_investor] == 0) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - vestingStartTime[_investor];
        uint256 totalVestingPeriod = getTierByContribution(contributions[_investor]).vestingPeriod;

        if (timeElapsed >= totalVestingPeriod) {
            return totalVested;
        } else {
            return (totalVested * timeElapsed) / totalVestingPeriod;
        }
    }

    function getTier(uint256 _contribution) internal view returns (uint256) {
        for (uint256 i = 0; i < tiers.length; i++) {
            if (_contribution >= tiers[i].minContribution && _contribution <= tiers[i].maxContribution) {
                return i;
            }
        }
        revert("No matching tier found");
    }

    function getTierByContribution(uint256 _contribution) internal view returns (Tier memory) {
        uint256 tierIndex = getTier(_contribution);
        return tiers[tierIndex];
    }
}
