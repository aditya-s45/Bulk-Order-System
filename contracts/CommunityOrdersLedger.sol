// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Forward declare interfaces for other contracts
interface IOrderProcessor {
    struct FulfillmentResult {
        uint256 finalPricePerUnit;
        uint256 netPaymentToManufacturer;
        uint256 platformFeeCollected;
        address[] retailersToRefund;
        uint256[] refundAmounts;
        uint256 totalValueForRewardCalc; // Value based on which rewards are calculated
    }

    function processOrder(
        CommunityOrdersLedger.ManufacturerOrder calldata order, // Use calldata for read-only struct
        CommunityOrdersLedger.RetailerContribution[] calldata contributions,
        uint256 platformFeePercent
    ) external pure returns (FulfillmentResult memory);
}

interface IRewardManager {
    function recordOrderRewards(
        uint256 orderId,
        uint256 totalRewardPool, // Amount of CommunityToken for this order's rewards
        uint256 totalUnitsInOrder,
        CommunityOrdersLedger.RetailerContribution[] calldata contributions
    ) external; // Needs to be callable by CommunityOrdersLedger
}

interface ICommunityToken is IERC20 {
    function mint(address to, uint256 amount) external;
}

contract CommunityOrdersLedger is Ownable, ReentrancyGuard {
    ICommunityToken public communityToken;
    IERC20 public paymentToken;
    IOrderProcessor public orderProcessor;
    IRewardManager public rewardManager;

    uint256 public nextOrderId = 1;
    uint256 public platformFeePercent; // e.g., 100 for 1% (10000 basis)
    uint256 public rewardPoolPerOrderBps; // e.g., 50 for 0.5% of order value

    // --- Struct Definitions ---
    struct DiscountTier {
        uint256 unitsThreshold;
        uint256 discountBps;    // Basis points
    }

    struct ManufacturerOrder {
        address manufacturer;
        string productId;
        uint256 minUnits;
        uint256 initialPricePerUnit;
        uint256 currentPricePerUnit; // Dynamically adjusted
        uint256 totalUnitsCommitted;
        uint256 totalPaymentTokenCollected;
        uint256 manufacturerStakeAmount;
        bool isActive;
        bool isFulfilled; // Different from fundsReleased; means processing is done
        DiscountTier[] discountTiers;
        uint256 orderCreationTime;
        uint256 fulfillmentDeadline;
    }

    struct RetailerContribution {
        address retailer;
        uint256 unitsOrdered;
        uint256 amountPaid; // In paymentToken
    }
    // --- End Struct Definitions ---

    mapping(uint256 => ManufacturerOrder) public orders;
    mapping(uint256 => RetailerContribution[]) public orderContributions;
    mapping(uint256 => mapping(address => uint256)) public retailerContributionIndex; // orderId => retailer => index+1

    event OrderCreated(uint256 indexed orderId, address indexed manufacturer, uint256 minUnits, uint256 initialPrice);
    event RetailerJoined(uint256 indexed orderId, address indexed retailer, uint256 units, uint256 paid);
    event PriceUpdated(uint256 indexed orderId, uint256 newPrice);
    event OrderReadyForProcessing(uint256 indexed orderId);
    event OrderProcessed(uint256 indexed orderId, uint256 finalPrice, uint256 manufacturerPayment);
    event StakeReturned(uint256 indexed orderId, address indexed manufacturer, uint256 amount);
    event OrderCancelled(uint256 indexed orderId);


    constructor(
        address _communityTokenAddr,
        address _paymentTokenAddr,
        address _initialOwner,
        uint256 _platformFeePct,
        uint256 _rewardPoolBps
    ) Ownable(_initialOwner) {
        communityToken = ICommunityToken(_communityTokenAddr);
        paymentToken = IERC20(_paymentTokenAddr);
        platformFeePercent = _platformFeePct;
        rewardPoolPerOrderBps = _rewardPoolBps;
    }

    function setServiceContracts(address _processorAddr, address _rewardMgrAddr) public onlyOwner {
        require(_processorAddr != address(0) && _rewardMgrAddr != address(0), "Invalid service address");
        orderProcessor = IOrderProcessor(_processorAddr);
        rewardManager = IRewardManager(_rewardMgrAddr);
    }

    function createOrder(
        string calldata _productId,
        uint256 _minUnits,
        uint256 _initialPricePerUnit,
        uint256 _stakeAmount,
        DiscountTier[] calldata _discountTiers,
        uint256 _deadlineDuration
    ) external nonReentrant {
        require(_minUnits > 0 && _initialPricePerUnit > 0, "Invalid params");
        if (_stakeAmount > 0) {
            require(communityToken.transferFrom(msg.sender, address(this), _stakeAmount), "Stake transfer failed");
        }

        uint256 orderId = nextOrderId++;
        ManufacturerOrder storage newOrder = orders[orderId];
        newOrder.manufacturer = msg.sender;
        newOrder.productId = _productId;
        newOrder.minUnits = _minUnits;
        newOrder.initialPricePerUnit = _initialPricePerUnit;
        newOrder.currentPricePerUnit = _initialPricePerUnit;
        newOrder.manufacturerStakeAmount = _stakeAmount;
        newOrder.isActive = true;
        newOrder.orderCreationTime = block.timestamp;
        newOrder.fulfillmentDeadline = block.timestamp + _deadlineDuration;

        // Deep copy discount tiers
        for (uint i = 0; i < _discountTiers.length; i++) {
            newOrder.discountTiers.push(_discountTiers[i]);
        }
        
        emit OrderCreated(orderId, msg.sender, _minUnits, _initialPricePerUnit);
    }

    function joinOrder(uint256 _orderId, uint256 _unitsToOrder) external nonReentrant {
        ManufacturerOrder storage currentOrder = orders[_orderId];
        require(currentOrder.isActive, "Order inactive");
        require(!currentOrder.isFulfilled, "Order fulfilled");
        require(block.timestamp < currentOrder.fulfillmentDeadline, "Deadline passed");
        require(_unitsToOrder > 0, "Units must be > 0");
        require(retailerContributionIndex[_orderId][msg.sender] == 0, "Already joined");

        uint256 cost = _unitsToOrder * currentOrder.currentPricePerUnit;
        require(paymentToken.transferFrom(msg.sender, address(this), cost), "Payment failed");

        currentOrder.totalUnitsCommitted += _unitsToOrder;
        currentOrder.totalPaymentTokenCollected += cost;

        orderContributions[_orderId].push(RetailerContribution(msg.sender, _unitsToOrder, cost));
        retailerContributionIndex[_orderId][msg.sender] = orderContributions[_orderId].length;

        _updateOrderPrice(_orderId);
        emit RetailerJoined(_orderId, msg.sender, _unitsToOrder, cost);

        if (currentOrder.totalUnitsCommitted >= currentOrder.minUnits) {
            emit OrderReadyForProcessing(_orderId);
        }
    }

    function _updateOrderPrice(uint256 _orderId) internal {
        ManufacturerOrder storage o = orders[_orderId];
        uint256 bestDiscountBps = 0;
        for (uint i = 0; i < o.discountTiers.length; i++) {
            if (o.totalUnitsCommitted >= o.discountTiers[i].unitsThreshold &&
                o.discountTiers[i].discountBps > bestDiscountBps) {
                bestDiscountBps = o.discountTiers[i].discountBps;
            }
        }
        uint256 newPrice = o.initialPricePerUnit;
        if (bestDiscountBps > 0) {
            newPrice = o.initialPricePerUnit - (o.initialPricePerUnit * bestDiscountBps / 10000);
        }
        if (newPrice != o.currentPricePerUnit) {
            o.currentPricePerUnit = newPrice;
            emit PriceUpdated(_orderId, newPrice);
        }
    }

    function executeOrderFulfillment(uint256 _orderId) external nonReentrant {
        require(address(orderProcessor) != address(0) && address(rewardManager) != address(0), "Services not set");
        ManufacturerOrder storage currentOrder = orders[_orderId];
        require(currentOrder.isActive, "Order not active or already processed");
        require(currentOrder.totalUnitsCommitted >= currentOrder.minUnits, "Min units not met");
        // require(msg.sender == currentOrder.manufacturer || msg.sender == owner(), "Not authorized"); // Auth

        currentOrder.isActive = false; // Prevent further joins or changes
        currentOrder.isFulfilled = true; // Mark as processing complete

        IOrderProcessor.FulfillmentResult memory result = orderProcessor.processOrder(
            orders[_orderId], // Pass a copy of the order struct (calldata if pure)
            orderContributions[_orderId], // Pass a copy of contributions
            platformFeePercent
        );

        // 1. Refunds
        for (uint i = 0; i < result.retailersToRefund.length; i++) {
            if (result.refundAmounts[i] > 0) {
                paymentToken.transfer(result.retailersToRefund[i], result.refundAmounts[i]);
            }
        }

        // 2. Manufacturer Payment
        if (result.netPaymentToManufacturer > 0) {
            paymentToken.transfer(currentOrder.manufacturer, result.netPaymentToManufacturer);
        }

        // 3. Platform Fee
        if (result.platformFeeCollected > 0) {
            paymentToken.transfer(owner(), result.platformFeeCollected); // To platform owner
        }

        // 4. Return Stake
        if (currentOrder.manufacturerStakeAmount > 0) {
            communityToken.transfer(currentOrder.manufacturer, currentOrder.manufacturerStakeAmount);
            emit StakeReturned(_orderId, currentOrder.manufacturer, currentOrder.manufacturerStakeAmount);
        }
        
        // 5. Record Rewards
        uint256 totalRewardPoolForOrder = (result.totalValueForRewardCalc * rewardPoolPerOrderBps) / 10000;
        if (totalRewardPoolForOrder > 0) {
            // CommunityOrdersLedger needs to have these tokens or be a minter.
            // Option A: Transfer from this contract's balance to RewardManager
            communityToken.transfer(address(rewardManager), totalRewardPoolForOrder);
            rewardManager.recordOrderRewards(
                _orderId,
                totalRewardPoolForOrder,
                currentOrder.totalUnitsCommitted,
                orderContributions[_orderId] // Pass contributions again
            );
            // Option B: If RewardManager can mint, just call it with the amount.
        }

        emit OrderProcessed(_orderId, result.finalPricePerUnit, result.netPaymentToManufacturer);
    }
    
    function cancelOrder(uint256 _orderId) external nonReentrant {
        ManufacturerOrder storage o = orders[_orderId];
        require(o.manufacturer == msg.sender || msg.sender == owner(), "Not authorized");
        require(o.isActive, "Order not active");
        require(!o.isFulfilled, "Order already fulfilled");
        // Typically, cancel if deadline passed AND min units not met
        require(block.timestamp >= o.fulfillmentDeadline && o.totalUnitsCommitted < o.minUnits, "Cancel conditions not met");

        o.isActive = false;
        RetailerContribution[] memory contributions = orderContributions[_orderId];
        for (uint i = 0; i < contributions.length; i++) {
            if (contributions[i].amountPaid > 0) {
                paymentToken.transfer(contributions[i].retailer, contributions[i].amountPaid);
            }
        }
        if (o.manufacturerStakeAmount > 0) {
            communityToken.transfer(o.manufacturer, o.manufacturerStakeAmount);
            emit StakeReturned(_orderId, o.manufacturer, o.manufacturerStakeAmount);
        }
        emit OrderCancelled(_orderId);
    }

    // --- Getter for other contracts if they need to pull data (use with caution for gas) ---
    function getOrder(uint256 _orderId) external view returns (ManufacturerOrder memory) {
        return orders[_orderId];
    }
    function getOrderContributions(uint256 _orderId) external view returns (RetailerContribution[] memory) {
        return orderContributions[_orderId];
    }
}