// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentSkill} from "../src/AgentSkill.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockReputationRegistry} from "./mocks/MockReputationRegistry.sol";

/// @dev Deliberately non-view implementation called through AgentSkill's view-only interface.
contract ReenteringIdentity {
    address public target;
    address public agentOwner;

    function configure(address target_, address agentOwner_) external {
        target = target_;
        agentOwner = agentOwner_;
    }

    function ownerOf(uint256) external returns (address) {
        // The source is also the application owner in this test, so only STATICCALL blocks this mutation.
        (bool succeeded,) =
            target.call(abi.encodeWithSignature("setReputationMetric(string,string)", "tampered", ""));
        require(!succeeded, "static boundary bypassed");
        return agentOwner;
    }
}

contract ExhaustingReputation {
    function getIdentityRegistry() external pure returns (address) {
        return 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    }

    function getSummary(uint256, address[] calldata, string calldata, string calldata)
        external
        pure
        returns (uint64 count, int128 value, uint8 decimals)
    {
        assembly ("memory-safe") {
            for {} 1 {} {}
        }
    }
}

contract AdversarialSourcesTest is Test {
    address internal constant IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant REPUTATION = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;

    function test_staticIdentityReadCannotMutateEvenWithApplicationOwnerAuthority() public {
        vm.etch(IDENTITY, address(new ReenteringIdentity()).code);
        AgentSkill app = new AgentSkill(IDENTITY);
        address agentOwner = makeAddr("agent owner");
        ReenteringIdentity(IDENTITY).configure(address(app), agentOwner);
        vm.prank(agentOwner);
        app.registerSkill(1, "solidity");
        assertEq(app.reputationTag1(), "starred");
        assertEq(app.policyVersion(), 0);
        assertEq(app.getAgentSkills(1).length, 1);
    }

    function test_sourceGasExhaustionIsBoundedAndCannotFabricateScores() public {
        vm.etch(IDENTITY, address(new MockIdentityRegistry()).code);
        vm.etch(REPUTATION, address(new ExhaustingReputation()).code);
        MockIdentityRegistry(IDENTITY).setOwner(1, address(this));
        AgentSkill app = new AgentSkill(address(this));
        address[] memory clients = new address[](1);
        clients[0] = makeAddr("trusted publisher");
        app.setTrustedClients(clients);
        bytes32 skill = app.registerSkill(1, "solidity");
        uint256 beforeGas = gasleft();
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, REPUTATION, 1));
        app.getScoreBreakdown(1, skill);
        assertLt(beforeGas - gasleft(), 2_100_000);
        assertEq(app.getAgentSkills(1).length, 1);
    }

    function test_oneFailedCandidateDoesNotProduceAMisleadingPartialLeaderboard() public {
        vm.etch(IDENTITY, address(new MockIdentityRegistry()).code);
        vm.etch(REPUTATION, address(new MockReputationRegistry()).code);
        AgentSkill app = new AgentSkill(address(this));
        address[] memory clients = new address[](1);
        clients[0] = makeAddr("trusted publisher");
        app.setTrustedClients(clients);
        for (uint256 id = 1; id <= 3; ++id) {
            MockIdentityRegistry(IDENTITY).setOwner(id, address(this));
            app.registerSkill(id, "solidity");
            MockReputationRegistry(REPUTATION).add(id, clients[0], 90, 0, "starred", "");
        }
        vm.mockCallRevert(
            REPUTATION,
            abi.encodeWithSelector(
                MockReputationRegistry.getSummary.selector, uint256(2), clients, "starred", ""
            ),
            "broken source"
        );
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, REPUTATION, 2));
        app.getTopAgents(keccak256("solidity"), 0, 50, 20);
        assertGt(app.getScoreBreakdown(1, keccak256("solidity")).total, 0);
    }
}
