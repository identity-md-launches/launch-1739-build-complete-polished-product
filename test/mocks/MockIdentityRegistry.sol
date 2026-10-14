// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Test-only registry installed at the official address; never deployed by the launch.
contract MockIdentityRegistry {
    mapping(uint256 => address) public owners;
    mapping(uint256 => string) public uris;

    function setOwner(uint256 agentId, address owner) external {
        owners[agentId] = owner;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        require(owners[agentId] != address(0), "ERC721NonexistentToken");
        return owners[agentId];
    }

    function tokenURI(uint256 agentId) external view returns (string memory) {
        require(owners[agentId] != address(0), "ERC721NonexistentToken");
        return uris[agentId];
    }
}
