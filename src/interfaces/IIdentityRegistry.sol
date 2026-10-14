// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ERC-8004 identity read interface
/// @notice Agent IDs are ERC-721 token IDs on the configured chain.
interface IIdentityRegistry {
    /// @notice Returns the current controller of an agent; reverts for an unregistered ID.
    /// @param agentId ERC-8004 token ID.
    /// @return owner Current token owner.
    function ownerOf(uint256 agentId) external view returns (address owner);

    /// @notice Returns the agent's registration document URI.
    /// @param agentId ERC-8004 token ID.
    /// @return uri Registration document location.
    function tokenURI(uint256 agentId) external view returns (string memory uri);
}
