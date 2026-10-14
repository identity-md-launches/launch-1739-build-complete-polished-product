// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Test-only registry reproducing the storage layout and getSummary loop of the verified Ethereum
/// ReputationRegistry implementation (getVersion() == "2.0.0"): every stored record of every listed client,
/// including revoked ones and ones under other tags, is loaded before filtering. Its gas therefore grows
/// with the agent's whole history, which is what AgentSkill's per-source gas budget has to tolerate.
contract OfficialLikeReputationRegistry {
    struct Feedback {
        int128 value;
        uint8 valueDecimals;
        bool isRevoked;
        string tag1;
        string tag2;
    }

    struct Accumulator {
        int256 sum;
        uint64 count;
        bytes32 tag1Hash;
        bytes32 tag2Hash;
        uint64[19] decimalCounts;
    }

    mapping(uint256 => mapping(address => mapping(uint64 => Feedback))) internal _feedback;
    mapping(uint256 => mapping(address => uint64)) internal _lastIndex;

    function getIdentityRegistry() external pure returns (address) {
        return 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    }

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2
    ) external {
        uint64 index = ++_lastIndex[agentId][msg.sender];
        _feedback[agentId][msg.sender][index] =
            Feedback({value: value, valueDecimals: valueDecimals, isRevoked: false, tag1: tag1, tag2: tag2});
    }

    function revokeFeedback(uint256 agentId, uint64 index) external {
        _feedback[agentId][msg.sender][index].isRevoked = true;
    }

    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals) {
        require(clientAddresses.length > 0, "clientAddresses required");
        Accumulator memory a;
        a.tag1Hash = keccak256(bytes(tag1));
        a.tag2Hash = keccak256(bytes(tag2));
        for (uint256 i; i < clientAddresses.length; i++) {
            _client(agentId, clientAddresses[i], a);
        }
        if (a.count == 0) return (0, 0, 0);
        uint8 modeDecimals;
        uint64 maxCount;
        for (uint8 d; d <= 18; d++) {
            if (a.decimalCounts[d] > maxCount) {
                maxCount = a.decimalCounts[d];
                modeDecimals = d;
            }
        }
        int256 average = a.sum / int256(uint256(a.count));
        summaryValue = int128(average / int256(10 ** uint256(18 - modeDecimals)));
        summaryValueDecimals = modeDecimals;
        count = a.count;
    }

    function _client(uint256 agentId, address client, Accumulator memory a) internal view {
        uint64 lastIndex = _lastIndex[agentId][client];
        for (uint64 j = 1; j <= lastIndex; j++) {
            _accumulate(a, _feedback[agentId][client][j]);
        }
    }

    function _accumulate(Accumulator memory a, Feedback storage fb) internal view {
        bytes32 emptyHash = keccak256(bytes(""));
        if (fb.isRevoked) return;
        if (emptyHash != a.tag1Hash && a.tag1Hash != keccak256(bytes(fb.tag1))) return;
        if (emptyHash != a.tag2Hash && a.tag2Hash != keccak256(bytes(fb.tag2))) return;
        int256 factor = int256(10 ** uint256(18 - fb.valueDecimals));
        a.decimalCounts[fb.valueDecimals]++;
        a.sum += fb.value * factor;
        a.count++;
    }
}
