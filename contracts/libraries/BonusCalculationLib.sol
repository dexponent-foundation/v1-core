// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title BonusCalculationLib
 * @notice Library containing deposit bonus math used by DexponentProtocol.
 */
library BonusCalculationLib {
    /**
     * @notice Computes the expected yield (in principal units).
     * @param principal The user’s deposit amount in principal token
     * @param benchYield The benchmark yield in percentage (e.g., 10 for 10%)
     * @param depositMaturity The chosen deposit maturity in seconds
     * @return expectedYield The yield in principal units
     *
     * Formula: ( principal * benchYield * depositMaturity ) / ( 100 * 365 days )
     */
    function computeExpectedYield(
        uint256 principal,
        uint256 benchYield,
        uint256 depositMaturity
    ) internal pure returns (uint256 expectedYield) {
        // e.g. (principal * benchYield * depositMaturity) / (100 * 365 days)
        expectedYield = (principal * benchYield * depositMaturity) / (100 * 365 days);
    }

    /**
     * @notice Given an expected yield in principal units, convert to DXP using price scaling
     * @param expectedYield The yield in principal units
     * @param priceScaled A scaled price of DXP in terms of principal. e.g. 1 DXP = X units
     *        If 0 => fallback to 1e18 or some default if needed
     * @return yieldInDXP The yield denominated in DXP
     */
    function convertYieldToDXP(
        uint256 expectedYield,
        uint256 priceScaled
    ) internal pure returns (uint256 yieldInDXP) {
        // If pricing info is not available => fallback to 1 DXP = 1 principal
        if (priceScaled == 0) {
            priceScaled = 1e18;
        }
        // yieldInDXP = ( expectedYield * 1e18 ) / priceScaled
        yieldInDXP = (expectedYield * 1e18) / priceScaled;
    }

    /**
     * @notice Given yieldInDXP and depositBonusRatio, compute the deposit bonus in DXP
     * @param yieldInDXP The yield in DXP
     * @param depositBonusRatio The bonus ratio in percentage (e.g., 70 for 70%)
     * @return bonusDXP The deposit bonus in DXP
     */
    function computeDepositBonus(
        uint256 yieldInDXP,
        uint256 depositBonusRatio
    ) internal pure returns (uint256 bonusDXP) {
        bonusDXP = (yieldInDXP * depositBonusRatio) / 100;
    }
}
