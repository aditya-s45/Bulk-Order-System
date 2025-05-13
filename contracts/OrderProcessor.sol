// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Import or define structs to match CommunityOrdersLedger
// For simplicity here, we'll assume the interface definition in CommunityOrdersLedger is sufficient
// or we'd redefine the structs here.
import "./CommunityOrdersLedger.sol"; // This allows using CommunityOrdersLedger.StructName

contract OrderProcessor {

    // This function is PURE. It does not modify state or read external state.
    // It calculates results based on inputs.
    function processOrder(
        CommunityOrdersLedger.ManufacturerOrder calldata order,
        CommunityOrdersLedger.RetailerContribution[] calldata contributions,
        uint256 platformFeePercent
    ) external pure returns (IOrderProcessor.FulfillmentResult memory result) {
        
        // 1. Determine Final Price (same logic as _updateOrderPrice but for final calc)
        uint256 finalPrice = order.initialPricePerUnit;
        uint256 bestDiscountBps = 0;
        for (uint i = 0; i < order.discountTiers.length; i++) {
            if (order.totalUnitsCommitted >= order.discountTiers[i].unitsThreshold &&
                order.discountTiers[i].discountBps > bestDiscountBps) {
                bestDiscountBps = order.discountTiers[i].discountBps;
            }
        }
        if (bestDiscountBps > 0) {
            finalPrice = order.initialPricePerUnit - (order.initialPricePerUnit * bestDiscountBps / 10000);
        }
        result.finalPricePerUnit = finalPrice;

        // 2. Calculate total value and fees
        uint256 grossOrderValue = order.totalUnitsCommitted * finalPrice;
        result.totalValueForRewardCalc = grossOrderValue; // Rewards based on this final value
        result.platformFeeCollected = (grossOrderValue * platformFeePercent) / 10000;
        result.netPaymentToManufacturer = grossOrderValue - result.platformFeeCollected;

        // 3. Calculate Refunds
        // Temporary arrays for refunds. Max possible refunds = number of contributions.
        address[] memory tempRetailersToRefund = new address[](contributions.length);
        uint256[] memory tempRefundAmounts = new uint256[](contributions.length);
        uint256 refundCount = 0;

        for (uint i = 0; i < contributions.length; i++) {
            CommunityOrdersLedger.RetailerContribution calldata contrib = contributions[i];
            uint256 idealPayment = contrib.unitsOrdered * finalPrice;
            if (contrib.amountPaid > idealPayment) {
                tempRetailersToRefund[refundCount] = contrib.retailer;
                tempRefundAmounts[refundCount] = contrib.amountPaid - idealPayment;
                refundCount++;
            }
        }
        
        // Copy to dynamically sized arrays for return
        result.retailersToRefund = new address[](refundCount);
        result.refundAmounts = new uint256[](refundCount);
        for (uint i = 0; i < refundCount; i++) {
            result.retailersToRefund[i] = tempRetailersToRefund[i];
            result.refundAmounts[i] = tempRefundAmounts[i];
        }

        return result;
    }
}