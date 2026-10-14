// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Official ERC-8004 reputation read interface
interface IReputationRegistry {
    /// @notice Returns the identity registry associated with this reputation registry.
    /// @return registry ERC-8004 identity registry address.
    function getIdentityRegistry() external view returns (address registry);

    /// @notice Aggregates non-revoked feedback from an explicit client set and optional tags.
    /// @param agentId Registered agent token ID.
    /// @param clientAddresses Nonempty list of feedback publishers to trust.
    /// @param tag1 Primary metric filter; AgentSkill requires a percentage quality metric.
    /// @param tag2 Optional secondary metric filter.
    /// @return count Number of matching, non-revoked records (not a completed-job count).
    /// @return summaryValue Signed aggregate value.
    /// @return summaryValueDecimals Decimal places in the aggregate value.
    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);
}
