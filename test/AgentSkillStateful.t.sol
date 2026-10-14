// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AgentSkill} from "src/AgentSkill.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockWorkHistory} from "./mocks/MockWorkHistory.sol";

/// @dev A controllable external summary source; scoring remains entirely in the application under test.
contract StatefulReputationSource {
    struct Summary {
        uint64 count;
        int128 value;
    }
    mapping(uint256 => Summary) internal summaries;
    mapping(uint256 => bool) public failing;

    function getIdentityRegistry() external pure returns (address) {
        return 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    }

    function set(uint256 id, uint64 count, int128 value) external {
        summaries[id] = Summary(count, value);
    }

    /// @dev A per-agent outage, like a history too long for the source gas budget.
    function setFailing(uint256 id, bool value) external {
        failing[id] = value;
    }

    function getSummary(uint256 id, address[] calldata, string calldata, string calldata)
        external
        view
        returns (uint64, int128, uint8)
    {
        require(!failing[id], "summary unavailable");
        Summary memory summary = summaries[id];
        return (summary.count, summary.value, 0);
    }
}

/// @dev Model keys are small actor/skill indices, independent of production's token IDs and skill hashes.
/// Every attempted action checks success or its exact expected error; unexpected reverts cannot be discarded.
contract AgentSkillModelHandler is Test {
    uint256 public constant AGENTS = 6;
    uint256 public constant SKILLS = 3;
    uint256 public constant WALLETS = 5;
    AgentSkill public immutable app;
    MockIdentityRegistry public immutable identity;
    StatefulReputationSource public immutable reputation;
    MockWorkHistory public immutable work;
    address internal immutable admin;

    uint256[6] public controller;
    mapping(uint256 => mapping(uint256 => bool)) public known;
    mapping(uint256 => mapping(uint256 => bool)) public active;
    mapping(uint256 => mapping(uint256 => uint256)) public votes;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => bool))) public identityVote;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => bool))) public walletVote;
    /// @dev Active list mirror: swap-and-pop on hide, append on (re)activation, like the application.
    mapping(uint256 => uint256[]) internal agentOrder;
    mapping(uint256 => mapping(uint256 => uint256)) internal position;
    mapping(uint256 => uint256[]) internal candidateOrder;
    uint256[] internal catalogOrder;
    bool[3] internal inCatalog;
    uint64[6] public feedbackCount;
    uint16[6] public rating;
    uint64[6] public completedWork;
    uint64[6] public acceptedWork;
    bool[6] public unreadable;
    bool public useWork;
    uint64 public version = 1;
    uint256 public successfulRegistrations;
    uint256 public successfulEndorsements;
    uint256 public rejectedActions;

    constructor(
        AgentSkill app_,
        MockIdentityRegistry identity_,
        StatefulReputationSource reputation_,
        MockWorkHistory work_
    ) {
        app = app_;
        identity = identity_;
        reputation = reputation_;
        work = work_;
        admin = msg.sender;
        for (uint256 i; i < AGENTS; ++i) {
            controller[i] = i % WALLETS;
            identity.setOwner(agentId(i), wallet(controller[i]));
        }
        // Seed reachable nonempty states. The fuzzer can subsequently hide all of them.
        _register(0, 0);
        _register(1, 0);
        _register(0, 1);
        _register(2, 2);
        _endorse(1, 0, 0);
        _endorse(1, 0, 1);
    }

    function agentId(uint256 index) public pure returns (uint256) {
        return index == 5 ? type(uint256).max : index;
    }

    function wallet(uint256 index) public pure returns (address) {
        return address(uint160(0x1000 + index));
    }

    function skillName(uint256 index) public pure returns (string memory) {
        if (index == 0) return "solidity";
        if (index == 1) return "research";
        return "ui/ux";
    }

    function skillId(uint256 index) public pure returns (bytes32) {
        return keccak256(bytes(skillName(index)));
    }

    function agentSkills(uint256 index) external view returns (uint256[] memory) {
        return agentOrder[index];
    }

    function candidates(uint256 index) external view returns (uint256[] memory) {
        return candidateOrder[index];
    }

    function catalog() external view returns (uint256[] memory) {
        return catalogOrder;
    }

    function register(uint8 agentSeed, uint8 skillSeed) external {
        _register(bound(agentSeed, 0, AGENTS - 1), bound(skillSeed, 0, SKILLS - 1));
    }

    function hide(uint8 agentSeed, uint8 skillSeed) external {
        uint256 agent = bound(agentSeed, 0, AGENTS - 1);
        uint256 skill = bound(skillSeed, 0, SKILLS - 1);
        bytes memory expected =
            active[agent][skill] ? bytes("") : abi.encodeWithSelector(AgentSkill.SkillNotActive.selector);
        _call(
            wallet(controller[agent]),
            abi.encodeCall(AgentSkill.hideSkill, (agentId(agent), skillId(skill))),
            expected
        );
        if (expected.length != 0) return;
        active[agent][skill] = false;
        uint256[] storage order = agentOrder[agent];
        uint256 last = order.length - 1;
        uint256 at = position[agent][skill];
        if (at != last) {
            uint256 moved = order[last];
            order[at] = moved;
            position[agent][moved] = at;
        }
        order.pop();
        position[agent][skill] = 0;
    }

    /// @dev Makes one agent's reputation summary unreadable (or readable again) without touching the app.
    function outage(uint8 agentSeed, bool failing) external {
        uint256 agent = bound(agentSeed, 0, AGENTS - 1);
        unreadable[agent] = failing;
        reputation.setFailing(agentId(agent), failing);
    }

    function endorse(uint8 voterSeed, uint8 targetSeed, uint8 skillSeed) external {
        _endorse(
            bound(voterSeed, 0, AGENTS - 1), bound(targetSeed, 0, AGENTS - 1), bound(skillSeed, 0, SKILLS - 1)
        );
    }

    function transfer(uint8 agentSeed, uint8 walletSeed) external {
        uint256 agent = bound(agentSeed, 0, AGENTS - 1);
        uint256 newOwner = bound(walletSeed, 0, WALLETS - 1);
        controller[agent] = newOwner;
        identity.setOwner(agentId(agent), wallet(newOwner));
    }

    function unauthorized(uint8 agentSeed, uint8 skillSeed, uint8 actionSeed) external {
        uint256 agent = bound(agentSeed, 0, AGENTS - 1);
        uint256 skill = bound(skillSeed, 0, SKILLS - 1);
        uint256 action = bound(actionSeed, 0, 2);
        address wrongOwner = wallet((controller[agent] + 1) % WALLETS);
        bytes memory callData;
        if (action == 0) {
            callData = abi.encodeCall(AgentSkill.registerSkill, (agentId(agent), skillName(skill)));
        } else if (action == 1) {
            callData = abi.encodeCall(AgentSkill.hideSkill, (agentId(agent), skillId(skill)));
        } else {
            callData = abi.encodeCall(
                AgentSkill.endorseSkill, (agentId(agent), agentId((agent + 1) % AGENTS), skillId(skill))
            );
        }
        _call(wrongOwner, callData, abi.encodeWithSelector(AgentSkill.NotAgentOwner.selector, agentId(agent)));
    }

    function evidence(
        uint8 agentSeed,
        uint16 ratingSeed,
        uint8 countSeed,
        uint64 completedSeed,
        uint64 acceptedSeed
    ) external {
        uint256 agent = bound(agentSeed, 0, AGENTS - 1);
        rating[agent] = uint16(bound(ratingSeed, 0, 100));
        feedbackCount[agent] = uint64(bound(countSeed, 0, 30));
        completedWork[agent] = completedSeed;
        acceptedWork[agent] = uint64(bound(acceptedSeed, 0, completedSeed));
        reputation.set(agentId(agent), feedbackCount[agent], int128(uint128(rating[agent])));
        work.set(agentId(agent), completedWork[agent], acceptedWork[agent]);
    }

    function workMode(bool enabled) external {
        vm.prank(admin);
        if (enabled) app.setWorkHistory(address(work));
        else app.clearWorkHistory();
        useWork = enabled;
        ++version;
    }

    function _register(uint256 agent, uint256 skill) internal {
        bytes memory expected =
            active[agent][skill] ? abi.encodeWithSelector(AgentSkill.SkillAlreadyActive.selector) : bytes("");
        bytes memory result = _call(
            wallet(controller[agent]),
            abi.encodeCall(
                AgentSkill.registerSkill, (agentId(agent), string.concat("  ", skillName(skill), "  "))
            ),
            expected
        );
        if (expected.length != 0) return;
        assertEq(abi.decode(result, (bytes32)), skillId(skill));
        if (!known[agent][skill]) {
            known[agent][skill] = true;
            candidateOrder[skill].push(agent);
            if (!inCatalog[skill]) {
                inCatalog[skill] = true;
                catalogOrder.push(skill);
            }
        }
        active[agent][skill] = true;
        position[agent][skill] = agentOrder[agent].length;
        agentOrder[agent].push(skill);
        ++successfulRegistrations;
    }

    function _endorse(uint256 voter, uint256 target, uint256 skill) internal {
        uint256 owner = controller[voter];
        bytes memory expected;
        if (voter == target || owner == controller[target]) {
            expected = abi.encodeWithSelector(AgentSkill.SelfEndorsement.selector);
        } else if (!active[target][skill]) {
            expected = abi.encodeWithSelector(AgentSkill.SkillNotActive.selector);
        } else if (identityVote[target][skill][voter] || walletVote[target][skill][owner]) {
            expected = abi.encodeWithSelector(AgentSkill.DuplicateEndorsement.selector);
        }
        _call(
            wallet(owner),
            abi.encodeCall(AgentSkill.endorseSkill, (agentId(voter), agentId(target), skillId(skill))),
            expected
        );
        if (expected.length != 0) return;
        identityVote[target][skill][voter] = true;
        walletVote[target][skill][owner] = true;
        ++votes[target][skill];
        ++successfulEndorsements;
    }

    function _call(address caller, bytes memory data, bytes memory expectedError)
        internal
        returns (bytes memory result)
    {
        vm.prank(caller);
        (bool success, bytes memory returned) = address(app).call(data);
        if (expectedError.length == 0) {
            assertTrue(success, "valid model action unexpectedly reverted");
        } else {
            assertFalse(success, "invalid model action unexpectedly succeeded");
            assertEq(returned, expectedError, "wrong rejection reason");
            ++rejectedActions;
        }
        return returned;
    }
}

/// @dev Endorsements are votes, so random sequence conservation is tested despite the absence of custody.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract AgentSkillStatefulTest is StdInvariant, Test {
    AgentSkill internal app;
    AgentSkillModelHandler internal model;

    function setUp() public {
        address registry = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
        address reputation = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
        vm.etch(registry, address(new MockIdentityRegistry()).code);
        vm.etch(reputation, address(new StatefulReputationSource()).code);
        app = new AgentSkill(address(this));
        address[] memory clients = new address[](1);
        clients[0] = makeAddr("stateful publisher");
        app.setTrustedClients(clients);
        model = new AgentSkillModelHandler(
            app, MockIdentityRegistry(registry), StatefulReputationSource(reputation), new MockWorkHistory()
        );
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = AgentSkillModelHandler.register.selector;
        selectors[1] = AgentSkillModelHandler.hide.selector;
        selectors[2] = AgentSkillModelHandler.endorse.selector;
        selectors[3] = AgentSkillModelHandler.transfer.selector;
        selectors[4] = AgentSkillModelHandler.unauthorized.selector;
        selectors[5] = AgentSkillModelHandler.evidence.selector;
        selectors[6] = AgentSkillModelHandler.workMode.selector;
        selectors[7] = AgentSkillModelHandler.outage.selector;
        targetContract(address(model));
        targetSelector(FuzzSelector({addr: address(model), selectors: selectors}));
    }

    /// @notice Unique catalog/candidate membership and active lists equal the independently recorded actions,
    /// including the swap-and-pop order the application documents for hidden skills.
    function invariant_catalogAndSkillsMatchTheModel() public view {
        uint256[] memory catalog = model.catalog();
        (AgentSkill.Skill[] memory actualCatalog, uint256 total) = app.getSkills(0, 50);
        assertEq(total, catalog.length);
        assertEq(actualCatalog.length, catalog.length);
        for (uint256 i; i < catalog.length; ++i) {
            assertEq(actualCatalog[i].id, model.skillId(catalog[i]));
            assertEq(actualCatalog[i].name, model.skillName(catalog[i]));
            assertEq(actualCatalog[i].endorsements, 0);
            assertEq(app.skillAgentCount(actualCatalog[i].id), model.candidates(catalog[i]).length);
        }
        for (uint256 agent; agent < 6; ++agent) {
            AgentSkill.Skill[] memory actual = app.getAgentSkills(model.agentId(agent));
            uint256[] memory order = model.agentSkills(agent);
            assertEq(actual.length, order.length, "active skill count differs from the model");
            for (uint256 j; j < order.length; ++j) {
                uint256 skill = order[j];
                assertTrue(model.active(agent, skill), "model lists an inactive skill");
                assertEq(actual[j].id, model.skillId(skill), "active skill order differs from the model");
                assertEq(actual[j].name, model.skillName(skill));
                assertEq(actual[j].endorsements, model.votes(agent, skill));
            }
        }
    }

    /// @notice Every counted vote has exactly one identity and historical wallet record, even after transfer.
    function invariant_endorsementsAreConservedAndIsolatedPerPair() public view {
        uint256 totalVotes;
        for (uint256 agent; agent < 6; ++agent) {
            for (uint256 skill; skill < 3; ++skill) {
                uint256 identities;
                uint256 wallets;
                for (uint256 voter; voter < 6; ++voter) {
                    bool recorded = model.identityVote(agent, skill, voter);
                    assertEq(
                        app.hasEndorsed(model.agentId(agent), model.skillId(skill), model.agentId(voter)),
                        recorded
                    );
                    if (recorded) ++identities;
                }
                for (uint256 walletIndex; walletIndex < 5; ++walletIndex) {
                    bool recorded = model.walletVote(agent, skill, walletIndex);
                    assertEq(
                        app.hasWalletEndorsed(
                            model.agentId(agent), model.skillId(skill), model.wallet(walletIndex)
                        ),
                        recorded
                    );
                    if (recorded) ++wallets;
                }
                assertEq(identities, wallets);
                assertEq(identities, model.votes(agent, skill));
                totalVotes += identities;
            }
        }
        assertEq(totalVotes, model.successfulEndorsements());
    }

    /// @notice Live evidence, current history mode, and visibility are reflected in all rankings after every action.
    function invariant_rankingsContainExactlyActiveAgentsWithCurrentScores() public view {
        assertEq(app.policyVersion(), model.version());
        for (uint256 skill; skill < 3; ++skill) {
            (AgentSkill.RankedAgent[] memory ranked, uint256 next, uint256 total) =
                app.getTopAgents(model.skillId(skill), 0, 50, 20);
            assertEq(total, model.candidates(skill).length);
            assertEq(next, total);
            uint256 activeCount;
            uint256 unreadableCount;
            for (uint256 agent; agent < 6; ++agent) {
                if (!model.active(agent, skill)) continue;
                ++activeCount;
                if (model.unreadable(agent)) ++unreadableCount;
                uint256 occurrences;
                for (uint256 i; i < ranked.length; ++i) {
                    if (ranked[i].agentId != model.agentId(agent)) continue;
                    ++occurrences;
                    if (model.unreadable(agent)) {
                        // Reported, never scored: no partial figure and an explicit source.
                        assertTrue(ranked[i].unavailable, "unreadable agent was scored");
                        assertEq(ranked[i].unavailableSource, address(app.REPUTATION_REGISTRY()));
                        assertEq(keccak256(abi.encode(ranked[i].score)), keccak256(abi.encode(_empty())));
                        assertGe(
                            i, ranked.length - unreadableTail(ranked), "unreadable agent inside top list"
                        );
                        continue;
                    }
                    assertFalse(ranked[i].unavailable, "readable agent flagged unavailable");
                    assertEq(ranked[i].unavailableSource, address(0));
                    _assertScore(agent, skill, ranked[i].score);
                    assertEq(
                        keccak256(abi.encode(ranked[i].score)),
                        keccak256(
                            abi.encode(app.getScoreBreakdown(model.agentId(agent), model.skillId(skill)))
                        )
                    );
                }
                assertEq(occurrences, 1, "active agent missing or duplicated");
            }
            assertEq(ranked.length, activeCount, "hidden or phantom agent ranked");
            uint256 scored = ranked.length - unreadableCount;
            for (uint256 i = 1; i < scored; ++i) {
                assertGe(ranked[i - 1].score.total, ranked[i].score.total);
                if (ranked[i - 1].score.total == ranked[i].score.total) {
                    assertLt(ranked[i - 1].agentId, ranked[i].agentId);
                }
            }
            // The unreadable tail follows candidate (first registration) order.
            uint256 cursor = scored;
            uint256[] memory order = model.candidates(skill);
            for (uint256 c; c < order.length; ++c) {
                uint256 agent = order[c];
                if (!model.active(agent, skill) || !model.unreadable(agent)) continue;
                assertEq(ranked[cursor++].agentId, model.agentId(agent), "unreadable tail out of scan order");
            }
            assertEq(cursor, ranked.length);
        }
    }

    function unreadableTail(AgentSkill.RankedAgent[] memory ranked) internal pure returns (uint256 tail) {
        for (uint256 i = ranked.length; i > 0; --i) {
            if (!ranked[i - 1].unavailable) break;
            ++tail;
        }
    }

    function _empty() internal pure returns (AgentSkill.ScoreBreakdown memory score) {}

    /// @dev Deterministic reachability check complements random sequence exploration.
    function test_handlerExercisesSuccessRejectionTransferAndBothHistoryModes() public {
        model.register(3, 1);
        model.register(3, 1);
        model.endorse(4, 3, 1);
        model.transfer(4, 1);
        model.endorse(4, 3, 1);
        model.hide(3, 1);
        model.endorse(2, 3, 1);
        model.register(3, 1);
        model.evidence(3, 90, 20, 20, 18);
        model.workMode(true);
        invariant_catalogAndSkillsMatchTheModel();
        invariant_endorsementsAreConservedAndIsolatedPerPair();
        invariant_rankingsContainExactlyActiveAgentsWithCurrentScores();
        // An outage for the seeded top agent of skill 0 moves it to the reported tail, then back.
        model.outage(0, true);
        invariant_rankingsContainExactlyActiveAgentsWithCurrentScores();
        (AgentSkill.RankedAgent[] memory ranked,,) = app.getTopAgents(model.skillId(0), 0, 50, 20);
        assertEq(ranked.length, 2);
        assertEq(ranked[0].agentId, model.agentId(1));
        assertFalse(ranked[0].unavailable);
        assertEq(ranked[1].agentId, model.agentId(0));
        assertTrue(ranked[1].unavailable);
        uint256 seededAgent = model.agentId(0);
        bytes32 seededSkill = model.skillId(0);
        address reputationRegistry = address(app.REPUTATION_REGISTRY());
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentSkill.ScoreSourceUnavailable.selector, reputationRegistry, seededAgent
            )
        );
        app.getScoreBreakdown(seededAgent, seededSkill);
        model.outage(0, false);
        invariant_rankingsContainExactlyActiveAgentsWithCurrentScores();
        // Swap-and-pop: hiding agent 0's first skill moves its last skill into the gap.
        model.register(0, 2);
        model.hide(0, 0);
        AgentSkill.Skill[] memory skills = app.getAgentSkills(model.agentId(0));
        assertEq(skills.length, 2);
        assertEq(skills[0].id, model.skillId(2));
        assertEq(skills[1].id, model.skillId(1));
        invariant_catalogAndSkillsMatchTheModel();
        model.workMode(false);
        model.unauthorized(3, 1, 0);
        assertGt(model.successfulRegistrations(), 4);
        assertGt(model.successfulEndorsements(), 2);
        assertGt(model.rejectedActions(), 0);
        invariant_rankingsContainExactlyActiveAgentsWithCurrentScores();
    }

    function _assertScore(uint256 agent, uint256 skill, AgentSkill.ScoreBreakdown memory score)
        internal
        view
    {
        assertEq(score.policyVersion, model.version());
        assertEq(score.feedbackCount, model.feedbackCount(agent));
        assertEq(score.reputationValue, int128(uint128(model.rating(agent))));
        assertEq(score.reputationDecimals, 0);
        uint256 normalized = model.feedbackCount(agent) == 0 ? 0 : uint256(model.rating(agent)) * 100;
        assertEq(score.reputationBps, normalized);
        assertEq(score.reputationPoints, normalized * 3 / 5);
        assertEq(score.endorsements, model.votes(agent, skill));
        assertEq(score.endorsementPoints, model.votes(agent, skill) * 75);
        if (model.useWork()) {
            assertEq(score.historySource, 1);
            uint256 completed = model.completedWork(agent);
            uint256 accepted = model.acceptedWork(agent);
            assertEq(score.completedWork, completed);
            assertEq(score.acceptedWork, accepted);
            if (completed < 20) {
                assertEq(score.historyBps, accepted * 500);
            } else {
                // The rounded acceptance percentage brackets the exact rational percentage.
                assertLe(score.historyBps * completed, accepted * 10_000);
                assertGt((score.historyBps + 1) * completed, accepted * 10_000);
            }
        } else {
            assertEq(score.historySource, 0);
            assertEq(score.completedWork, 0);
            assertEq(score.acceptedWork, 0);
            uint256 count = model.feedbackCount(agent);
            if (count >= 20) assertEq(score.historyBps, normalized);
            else assertEq(score.historyBps * 20, normalized * count);
        }
        assertLe(score.historyPoints * 4, score.historyBps);
        assertGt((score.historyPoints + 1) * 4, score.historyBps);
        assertEq(score.total, score.reputationPoints + score.historyPoints + score.endorsementPoints);
        assertLe(score.total, 10_000);
    }
}
