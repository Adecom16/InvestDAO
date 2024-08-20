// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

// RewardToken Contract
contract RewardToken is ERC20, Ownable {
    uint256 public constant INITIAL_SUPPLY = 1000000 * 10**18; // 1 million tokens with 18 decimals

    constructor(address initialOwner) ERC20("DAO Reward Token", "DRT") Ownable(initialOwner) {
        _mint(initialOwner, INITIAL_SUPPLY);
    }

    /**
     * @dev Function to mint new tokens.
     * @param to The address that will receive the minted tokens.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Function to burn tokens.
     * @param amount The amount of tokens to burn.
     */
    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }

    /**
     * @dev Function to burn tokens from a specific address.
     * @param from The address from which to burn tokens.
     * @param amount The amount of tokens to burn.
     */
    function burnFrom(address from, uint256 amount) public {
        _burn(from, amount);
    }
}

// Membership Contract
contract Membership is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    struct Member {
        uint256 contribution;
        uint256 votingPower;
        address delegate;
    }

    EnumerableSet.AddressSet private members;
    mapping(address => Member) public memberDetails;

    uint256 public totalContributions;

    event MemberJoined(address member, uint256 contribution);
    event ContributionIncreased(address member, uint256 amount);
    event Delegated(address member, address delegate);

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyMember() {
        require(members.contains(msg.sender), "Not a member");
        _;
    }

    function joinDAO() public payable {
        require(msg.value > 0, "Contribution must be greater than zero");
        
        if (members.add(msg.sender)) {
            memberDetails[msg.sender] = Member(msg.value, msg.value, address(0));
            emit MemberJoined(msg.sender, msg.value);
        } else {
            Member storage member = memberDetails[msg.sender];
            member.contribution += msg.value;
            member.votingPower += msg.value;
            emit ContributionIncreased(msg.sender, msg.value);
        }

        totalContributions += msg.value;
    }

    function delegateVote(address _delegate) public onlyMember {
        require(_delegate != msg.sender, "Cannot delegate to yourself");
        require(members.contains(_delegate), "Delegate must be a member");

        memberDetails[msg.sender].delegate = _delegate;
        emit Delegated(msg.sender, _delegate);
    }

    function getVotingPower(address _member) public view returns (uint256) {
        Member storage member = memberDetails[_member];
        if (member.delegate != address(0)) {
            return memberDetails[member.delegate].votingPower;
        }
        return member.votingPower;
    }

    function isMember(address _member) public view returns (bool) {
        return members.contains(_member);
    }
}

// Proposal and Voting Contract
contract ProposalAndVoting is Membership {
    struct Proposal {
        uint256 id;
        string description;
        uint256 amount;
        address payable recipient;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 votingDeadline;
        bool executed;
    }

    Proposal[] public proposals;
    uint256 public proposalCount;
    mapping(uint256 => mapping(address => bool)) public votes;

    event ProposalCreated(uint256 id, string description, uint256 amount, address recipient);
    event Voted(uint256 proposalId, address voter, bool vote);
    event ProposalExecuted(uint256 proposalId);

    constructor(address initialOwner) Membership(initialOwner) {}

    function createProposal(
        string memory _description,
        uint256 _amount,
        address payable _recipient
    ) public onlyMember {
        require(_amount <= address(this).balance, "Amount exceeds available funds");

        proposals.push(
            Proposal({
                id: proposalCount,
                description: _description,
                amount: _amount,
                recipient: _recipient,
                votesFor: 0,
                votesAgainst: 0,
                votingDeadline: block.timestamp + 7 days,
                executed: false
            })
        );

        emit ProposalCreated(proposalCount, _description, _amount, _recipient);
        proposalCount++;
    }

    function voteOnProposal(uint256 _proposalId, bool _support) public onlyMember {
        require(_proposalId < proposalCount, "Invalid proposal ID");
        require(!votes[_proposalId][msg.sender], "Member has already voted");
        require(block.timestamp <= proposals[_proposalId].votingDeadline, "Voting period has ended");

        Proposal storage proposal = proposals[_proposalId];

        if (_support) {
            proposal.votesFor += getVotingPower(msg.sender);
        } else {
            proposal.votesAgainst += getVotingPower(msg.sender);
        }

        votes[_proposalId][msg.sender] = true;
        emit Voted(_proposalId, msg.sender, _support);
    }

    function executeProposal(uint256 _proposalId) public onlyMember {
        require(_proposalId < proposalCount, "Invalid proposal ID");
        Proposal storage proposal = proposals[_proposalId];
        require(!proposal.executed, "Proposal already executed");
        require(block.timestamp > proposal.votingDeadline, "Voting period not yet ended");
        require(proposal.votesFor > proposal.votesAgainst, "Proposal did not pass");

        proposal.executed = true;
        (bool success, ) = proposal.recipient.call{value: proposal.amount}("");
        require(success, "Transfer failed");

        emit ProposalExecuted(_proposalId);
    }

    function getProposal(uint256 _proposalId) public view returns (Proposal memory) {
        require(_proposalId < proposalCount, "Invalid proposal ID");
        return proposals[_proposalId];
    }
}

// Fund Management Contract
contract FundManagement is ProposalAndVoting {
    uint256 public requiredApprovals;
    mapping(uint256 => uint256) public approvals;
    mapping(uint256 => mapping(address => bool)) public hasApproved;

    event FundsDistributed(address recipient, uint256 amount);
    event ApprovalReceived(uint256 proposalId, address approver);

    constructor(address _rewardToken, uint256 _requiredApprovals, address initialOwner) ProposalAndVoting(initialOwner) {
        requiredApprovals = _requiredApprovals;
    }

    modifier onlyUnexecutedProposal(uint256 _proposalId) {
        require(!proposals[_proposalId].executed, "Proposal already executed");
        _;
    }

    function approveProposal(uint256 _proposalId) public onlyMember onlyUnexecutedProposal(_proposalId) {
        require(!hasApproved[_proposalId][msg.sender], "Member has already approved");

        hasApproved[_proposalId][msg.sender] = true;
        approvals[_proposalId]++;

        emit ApprovalReceived(_proposalId, msg.sender);
    }

    function distributeFunds(uint256 _proposalId) public onlyMember onlyUnexecutedProposal(_proposalId) {
        require(approvals[_proposalId] >= requiredApprovals, "Not enough approvals");

        Proposal storage proposal = proposals[_proposalId];
        proposal.executed = true;

        (bool success, ) = proposal.recipient.call{value: proposal.amount}("");
        require(success, "Transfer failed");

        emit FundsDistributed(proposal.recipient, proposal.amount);
    }

    receive() external payable {
        totalContributions += msg.value;
    }
}
