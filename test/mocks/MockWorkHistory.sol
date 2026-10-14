// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Test-only adapter; this is deliberately not a production work ledger or attestation service.
contract MockWorkHistory {
    mapping(uint256 => uint64) public completed;
    mapping(uint256 => uint64) public accepted;
    bool public fail;
    address public identityRegistry = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;

    function set(uint256 id, uint64 completed_, uint64 accepted_) external {
        completed[id] = completed_;
        accepted[id] = accepted_;
    }

    function setFailure(bool value) external {
        fail = value;
    }

    function setIdentity(address value) external {
        identityRegistry = value;
    }

    function getWorkSummary(uint256 id) external view returns (uint64, uint64) {
        require(!fail, "work source failed");
        return (completed[id], accepted[id]);
    }
}
