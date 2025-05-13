// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol"; // If needed for admin functions
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Assuming CommunityOrdersLedger.RetailerContribution struct definition is accessible
// or define a compatible local struct/interface.
import "./CommunityOrdersLedger.sol"; // Allows using CommunityOrdersLedger.RetailerContribution

interface ICommunityTokenForRewards is IERC20 {
    // function mint(address to, uint256 amount) external; // If this contract can mint
}

contract RewardManager is Ownable, ReentrancyGuard {
    ICommunityTokenForRewards public communityToken;
    address public ledgerContractAddress; // Authorized CommunityOrdersLedger

    struct RewardInfo {
        uint256 amount;
        bool claimed;
    }
    // orderId => retailer => RewardInfo
    mapping(uint256 => mapping(address => RewardInfo)) public rewards;

    event RewardsRecorded(uint256 indexed orderId, address indexed retailer, uint256 amount);
    event RewardClaimed(uint256 indexed orderId, address indexed retailer, uint256 amount);

    constructor(address _communityTokenAddr, address _initialOwner) Ownable(_initialOwner) {
        communityToken = ICommunityTokenForRewards(_communityTokenAddr);
    }

    modifier onlyLedger() {
        require(msg.sender == ledgerContractAddress, "Caller is not the ledger contract");
        _;
    }

    function setLedgerContract(address _ledgerAddr) public onlyOwner {
        ledgerContractAddress = _ledgerAddr;
    }

    // Called by CommunityOrdersLedger. It assumes CommunityOrdersLedger has transferred
    // `totalRewardPool` tokens to this RewardManager contract.
    function recordOrderRewards(
        uint256 _orderId,
        uint256 _totalRewardPool, // This is the amount of tokens this contract should have received
        uint256 _totalUnitsInOrder,
        CommunityOrdersLedger.RetailerContribution[] calldata _contributions
    ) external nonReentrant onlyLedger {
        require(_totalRewardPool > 0 && _totalUnitsInOrder > 0, "Invalid reward params");
        // Check if this contract has enough tokens (it should have just received them)
        // This check is more of a safeguard.
        require(communityToken.balanceOf(address(this)) >= _totalRewardPool, "Insufficient token balance for rewards");


        uint256 distributedRewards = 0;
        for (uint i = 0; i < _contributions.length; i++) {
            CommunityOrdersLedger.RetailerContribution calldata c = _contributions[i];
            if (c.unitsOrdered > 0) {
                uint256 reward = (_totalRewardPool * c.unitsOrdered) / _totalUnitsInOrder;
                if (reward > 0) {
                    rewards[_orderId][c.retailer] = RewardInfo(reward, false);
                    distributedRewards += reward;
                    emit RewardsRecorded(_orderId, c.retailer, reward);
                }
            }
        }
        // Note: Due to integer division, distributedRewards might be slightly less than _totalRewardPool.
        // Any dust remains in this contract, can be managed by owner later.
    }

    function claimReward(uint256 _orderId) external nonReentrant {
        RewardInfo storage rewardInfo = rewards[_orderId][msg.sender];
        require(rewardInfo.amount > 0, "No reward");
        require(!rewardInfo.claimed, "Already claimed");

        rewardInfo.claimed = true;
        require(communityToken.transfer(msg.sender, rewardInfo.amount), "Reward transfer failed");
        emit RewardClaimed(_orderId, msg.sender, rewardInfo.amount);
    }
    
    // Optional: allow owner to withdraw any dust/unused tokens
    function withdrawDust(address _to, uint256 _amount) public onlyOwner {
        require(communityToken.transfer(_to, _amount), "Dust withdrawal failed");
    }
}