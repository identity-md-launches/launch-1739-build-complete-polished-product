// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentSkill} from "../src/AgentSkill.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockReputationRegistry} from "./mocks/MockReputationRegistry.sol";
import {OfficialLikeReputationRegistry} from "./mocks/OfficialLikeReputationRegistry.sol";

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

/// @dev Answers correctly but only after burning a fixed amount of gas, like a long official history.
contract SlowReputation {
    uint256 public constant BURN = 1_000_000;

    function getIdentityRegistry() external pure returns (address) {
        return 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    }

    function getSummary(uint256, address[] calldata, string calldata, string calldata)
        external
        view
        returns (uint64 count, int128 value, uint8 decimals)
    {
        uint256 start = gasleft();
        while (start - gasleft() < BURN) {}
        return (20, 80, 0);
    }
}

/// @dev ABI-incompatible registry: a successful call returning a single word instead of three.
contract MalformedReputation {
    function getIdentityRegistry() external pure returns (address) {
        return 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    }

    function getSummary(uint256, address[] calldata, string calldata, string calldata)
        external
        pure
        returns (uint64 count)
    {
        return 20;
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
        assertEq(app.reputationTag1(), "");
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
        assertLt(beforeGas - gasleft(), app.sourceGasBudget() + 200_000);
        assertEq(app.getAgentSkills(1).length, 1);
        // The budget, not the caller's gas, bounds the spend after the owner lowers it.
        app.setSourceGasBudget(1_000_000);
        beforeGas = gasleft();
        (AgentSkill.RankedAgent[] memory ranked,,) = app.getTopAgents(skill, 0, 50, 20);
        assertLt(beforeGas - gasleft(), 1_300_000);
        assertEq(ranked.length, 1);
        assertTrue(ranked[0].unavailable);
        assertEq(ranked[0].unavailableSource, REPUTATION);
        assertEq(ranked[0].score.total, 0);
        assertEq(ranked[0].score.policyVersion, 0);
    }

    function test_oneFailedCandidateIsReportedAndNeverHidesTheOthers() public {
        vm.etch(IDENTITY, address(new MockIdentityRegistry()).code);
        vm.etch(REPUTATION, address(new MockReputationRegistry()).code);
        AgentSkill app = new AgentSkill(address(this));
        address[] memory clients = new address[](1);
        clients[0] = makeAddr("trusted publisher");
        app.setTrustedClients(clients);
        for (uint256 id = 1; id <= 3; ++id) {
            MockIdentityRegistry(IDENTITY).setOwner(id, address(this));
            app.registerSkill(id, "solidity");
            MockReputationRegistry(REPUTATION)
                .add(id, clients[0], int128(int256(80 + id * 5)), 0, "starred", "");
        }
        vm.mockCallRevert(
            REPUTATION,
            abi.encodeWithSelector(MockReputationRegistry.getSummary.selector, uint256(2), clients, "", ""),
            "broken source"
        );
        bytes32 skill = keccak256("solidity");
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, REPUTATION, 2));
        app.getScoreBreakdown(2, skill);
        (AgentSkill.RankedAgent[] memory ranked, uint256 next,) = app.getTopAgents(skill, 0, 50, 20);
        assertEq(next, 3);
        assertEq(ranked.length, 3);
        assertEq(ranked[0].agentId, 3);
        assertEq(ranked[0].score.reputationBps, 9500);
        assertFalse(ranked[0].unavailable);
        assertEq(ranked[1].agentId, 1);
        assertEq(ranked[1].score.reputationBps, 8500);
        assertTrue(ranked[2].unavailable);
        assertEq(ranked[2].agentId, 2);
        assertEq(ranked[2].unavailableSource, REPUTATION);
        assertEq(ranked[2].score.total, 0);
        assertEq(ranked[2].score.feedbackCount, 0);
        // A result limit smaller than the page keeps every unavailable candidate visible after the top list.
        (ranked,,) = app.getTopAgents(skill, 0, 50, 1);
        assertEq(ranked.length, 2);
        assertEq(ranked[0].agentId, 3);
        assertTrue(ranked[1].unavailable);
        vm.clearMockedCalls();
        (ranked,,) = app.getTopAgents(skill, 0, 50, 20);
        assertEq(ranked.length, 3);
        assertEq(ranked[1].agentId, 2);
        assertFalse(ranked[2].unavailable);
    }

    function test_longOfficialHistoryIsScoredWithinBudgetAndReportedBeyondIt() public {
        vm.etch(IDENTITY, address(new MockIdentityRegistry()).code);
        vm.etch(REPUTATION, address(new OfficialLikeReputationRegistry()).code);
        MockIdentityRegistry(IDENTITY).setOwner(1, address(this));
        MockIdentityRegistry(IDENTITY).setOwner(2, address(this));
        address publisher = makeAddr("trusted publisher");
        address[] memory clients = new address[](1);
        clients[0] = publisher;
        AgentSkill app = new AgentSkill(address(this));
        app.setTrustedClients(clients);
        app.setReputationMetric("quality", "");
        bytes32 skill = app.registerSkill(1, "solidity");
        app.registerSkill(2, "solidity");
        OfficialLikeReputationRegistry registry = OfficialLikeReputationRegistry(REPUTATION);
        vm.startPrank(publisher);
        for (uint256 i; i < 320; ++i) {
            registry.giveFeedback(1, 90, 0, "quality", "green");
        }
        registry.giveFeedback(2, 80, 0, "quality", "green");
        vm.stopPrank();
        // Default budget: an agent with 320 official-shaped records is scored and ranks first.
        AgentSkill.ScoreBreakdown memory heavy = app.getScoreBreakdown(1, skill);
        assertEq(heavy.feedbackCount, 320);
        assertEq(heavy.total, 7650);
        (AgentSkill.RankedAgent[] memory ranked,,) = app.getTopAgents(skill, 0, 50, 20);
        assertEq(ranked.length, 2);
        assertEq(ranked[0].agentId, 1);
        assertEq(ranked[1].agentId, 2);
        assertFalse(ranked[0].unavailable);
        // The old 2,000,000 cap, now the minimum range's neighbourhood: the heavy agent is reported, not hidden.
        app.setSourceGasBudget(1_000_000);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, REPUTATION, 1));
        app.getScoreBreakdown(1, skill);
        assertEq(app.getScoreBreakdown(2, skill).reputationBps, 8000);
        (ranked,,) = app.getTopAgents(skill, 0, 50, 20);
        assertEq(ranked.length, 2);
        assertEq(ranked[0].agentId, 2);
        assertFalse(ranked[0].unavailable);
        assertEq(ranked[0].score.reputationBps, 8000);
        assertEq(ranked[1].agentId, 1);
        assertTrue(ranked[1].unavailable);
        assertEq(ranked[1].unavailableSource, REPUTATION);
    }

    function test_leaderboardPageStopsEarlyWhenCallGasRunsOutAndResumesFromItsCursor() public {
        vm.etch(IDENTITY, address(new MockIdentityRegistry()).code);
        vm.etch(REPUTATION, address(new SlowReputation()).code);
        AgentSkill app = new AgentSkill(address(this));
        address[] memory clients = new address[](1);
        clients[0] = makeAddr("trusted publisher");
        app.setTrustedClients(clients);
        bytes32 skill;
        for (uint256 id = 1; id <= 3; ++id) {
            MockIdentityRegistry(IDENTITY).setOwner(id, address(this));
            skill = app.registerSkill(id, "solidity");
        }
        uint256 budget = app.sourceGasBudget();
        uint256 required = budget + budget / 63 + app.CALL_GAS_RESERVE();
        // Enough gas for two reads of about 1,000,000 each plus one full budget reservation, not three.
        (AgentSkill.RankedAgent[] memory ranked, uint256 next, uint256 total) =
            app.getTopAgents{gas: required + 1_500_000}(skill, 0, 50, 20);
        assertEq(total, 3);
        assertEq(next, 2);
        assertEq(ranked.length, 2);
        assertEq(ranked[0].agentId, 1);
        assertEq(ranked[1].agentId, 2);
        assertFalse(ranked[0].unavailable);
        assertEq(ranked[0].score.total, 6800);
        (ranked, next,) = app.getTopAgents(skill, next, 50, 20);
        assertEq(next, 3);
        assertEq(ranked.length, 1);
        assertEq(ranked[0].agentId, 3);
        // No progress at all is an explicit error rather than an empty page with a stuck cursor.
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.InsufficientCallGas.selector, required));
        app.getTopAgents{gas: required - 1}(skill, 0, 50, 20);
    }

    function test_malformedRegistryAnswerIsReportedAsUnavailable() public {
        vm.etch(IDENTITY, address(new MockIdentityRegistry()).code);
        vm.etch(REPUTATION, address(new MalformedReputation()).code);
        MockIdentityRegistry(IDENTITY).setOwner(1, address(this));
        AgentSkill app = new AgentSkill(address(this));
        address[] memory clients = new address[](1);
        clients[0] = makeAddr("trusted publisher");
        app.setTrustedClients(clients);
        bytes32 skill = app.registerSkill(1, "solidity");
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, REPUTATION, 1));
        app.getScoreBreakdown(1, skill);
        (AgentSkill.RankedAgent[] memory ranked,,) = app.getTopAgents(skill, 0, 50, 20);
        assertEq(ranked.length, 1);
        assertTrue(ranked[0].unavailable);
        assertEq(ranked[0].unavailableSource, REPUTATION);
    }
}
