// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Optional adapter for an authoritative IMD work ledger
/// @notice Implement against the actual ledger before configuring it. Never infer accepted jobs from feedback.
/// @dev Counts must be final outcomes, deduplicated by job ID, with accepted <= completed.
interface IAgentWorkHistory {
    /// @notice Identifies the ERC-8004 identity namespace used by the adapter.
    /// @return registry Identity registry address.
    function identityRegistry() external view returns (address registry);

    /// @notice Reads historical final work outcomes for one agent.
    /// @param agentId ERC-8004 token ID, not a wallet address.
    /// @return completed Number of finalized jobs, including rejected jobs.
    /// @return accepted Number of those jobs accepted by their requester.
    function getWorkSummary(uint256 agentId) external view returns (uint64 completed, uint64 accepted);
}
