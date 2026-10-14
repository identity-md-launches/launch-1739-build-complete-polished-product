// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Behavioral test double: actual publisher/tag filtering, mixed-decimal averaging, revocation.
contract MockReputationRegistry {
    struct Feedback {
        address client;
        int128 value;
        uint8 decimals;
        string tag1;
        string tag2;
        bool revoked;
    }

    mapping(uint256 => Feedback[]) internal feedback;
    bool public fail;

    function getIdentityRegistry() external pure returns (address) {
        return 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    }

    function setFailure(bool value) external {
        fail = value;
    }

    function add(
        uint256 agentId,
        address client,
        int128 value,
        uint8 decimals,
        string memory tag1,
        string memory tag2
    ) external {
        require(decimals <= 18);
        feedback[agentId].push(Feedback(client, value, decimals, tag1, tag2, false));
    }

    function revoke(uint256 agentId, uint256 index) external {
        feedback[agentId][index].revoked = true;
    }

    function getSummary(
        uint256 agentId,
        address[] calldata clients,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 value, uint8 decimals) {
        require(!fail, "source failed");
        require(clients.length != 0, "clientAddresses required");
        int256 sum;
        uint64[19] memory frequency;
        for (uint256 i; i < feedback[agentId].length; ++i) {
            Feedback storage f = feedback[agentId][i];
            if (f.revoked) continue;
            if (bytes(tag1).length != 0 && keccak256(bytes(f.tag1)) != keccak256(bytes(tag1))) continue;
            if (bytes(tag2).length != 0 && keccak256(bytes(f.tag2)) != keccak256(bytes(tag2))) continue;
            bool trusted;
            for (uint256 j; j < clients.length; ++j) {
                if (clients[j] == f.client) trusted = true;
            }
            if (!trusted) continue;
            sum += int256(f.value) * int256(10 ** uint256(18 - f.decimals));
            ++frequency[f.decimals];
            ++count;
        }
        if (count == 0) return (0, 0, 0);
        uint64 most;
        for (uint8 d; d <= 18; ++d) {
            if (frequency[d] > most) {
                most = frequency[d];
                decimals = d;
            }
        }
        value = int128(sum / int256(uint256(count)) / int256(10 ** uint256(18 - decimals)));
    }
}
