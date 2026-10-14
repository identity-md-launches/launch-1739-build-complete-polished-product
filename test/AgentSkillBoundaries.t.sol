// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AgentSkillFixture} from "./helpers/AgentSkillFixture.sol";
import {AgentSkill} from "src/AgentSkill.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AgentSkillBoundariesTest is AgentSkillFixture {
    event SkillRegistered(uint256 indexed agentId, bytes32 indexed skillId, string name);
    event SkillHidden(uint256 indexed agentId, bytes32 indexed skillId);
    event SkillEndorsed(
        uint256 indexed agentId, bytes32 indexed skillId, uint256 indexed endorserId, address wallet
    );
    event TrustedClientsChanged(address[] clients, uint64 version);
    event ReputationMetricChanged(string tag1, string tag2, uint64 version);
    event WorkHistoryChanged(address indexed adapter, uint64 version);

    function test_mutationEventsUseCanonicalNamesAndCorrectIdentities() public {
        vm.expectEmit(true, true, false, true, address(app));
        emit SkillRegistered(1, SOLIDITY, "solidity");
        _register(1, "  SOLIDITY  ");
        vm.expectEmit(true, true, true, true, address(app));
        emit SkillEndorsed(1, SOLIDITY, 2, bob);
        _endorse(2, 1, SOLIDITY);
        vm.expectEmit(true, true, false, true, address(app));
        emit SkillHidden(1, SOLIDITY);
        _hide(1, SOLIDITY);
        vm.expectEmit(true, true, false, true, address(app));
        emit SkillRegistered(1, SOLIDITY, "solidity");
        _register(1, "Solidity");
        assertEq(app.getAgentSkills(1)[0].endorsements, 1);
    }

    function test_policyEventsIdentifyEveryVersionAndClearingRestoresFeedbackMode() public {
        _register(1, "solidity");
        address[] memory clients = new address[](2);
        clients[0] = publisher;
        clients[1] = carol;
        vm.expectEmit(false, false, false, true, address(app));
        emit TrustedClientsChanged(clients, 2);
        app.setTrustedClients(clients);
        vm.expectEmit(false, false, false, true, address(app));
        emit ReputationMetricChanged("quality", "audit", 3);
        app.setReputationMetric("quality", "audit");
        vm.expectEmit(true, false, false, true, address(app));
        emit WorkHistoryChanged(address(work), 4);
        app.setWorkHistory(address(work));
        work.set(1, 20, 20);
        assertEq(app.getScoreBreakdown(1, SOLIDITY).historyPoints, 2500);
        vm.expectEmit(true, false, false, true, address(app));
        emit WorkHistoryChanged(address(0), 5);
        app.clearWorkHistory();
        AgentSkill.ScoreBreakdown memory score = app.getScoreBreakdown(1, SOLIDITY);
        assertEq(score.policyVersion, 5);
        assertEq(score.historySource, 0);
        assertEq(score.completedWork, 0);
        assertEq(score.acceptedWork, 0);
        assertEq(score.historyPoints, 0);
    }

    function test_endorsementUniquenessIsScopedToBothTargetAndSkill() public {
        _register(1, "solidity");
        _register(1, "research");
        _register(3, "solidity");
        _endorse(2, 1, SOLIDITY);
        _endorse(2, 1, RESEARCH);
        _endorse(2, 3, SOLIDITY);
        assertEq(app.getAgentSkills(1)[0].endorsements, 1);
        assertEq(app.getAgentSkills(1)[1].endorsements, 1);
        assertEq(app.getAgentSkills(3)[0].endorsements, 1);
        for (uint256 i; i < 3; ++i) {
            uint256 target = i == 2 ? 3 : 1;
            bytes32 skill = i == 1 ? RESEARCH : SOLIDITY;
            assertTrue(app.hasEndorsed(target, skill, 2));
            assertTrue(app.hasWalletEndorsed(target, skill, bob));
            vm.prank(bob);
            vm.expectRevert(AgentSkill.DuplicateEndorsement.selector);
            app.endorseSkill(2, target, skill);
        }
        assertFalse(app.hasEndorsed(3, RESEARCH, 2));
        assertFalse(app.hasWalletEndorsed(3, RESEARCH, bob));
    }

    function test_failedEndorsementDoesNotConsumeIdentityOrWalletVote() public {
        _register(1, "solidity");
        _hide(1, SOLIDITY);
        vm.prank(bob);
        vm.expectRevert(AgentSkill.SkillNotActive.selector);
        app.endorseSkill(2, 1, SOLIDITY);
        assertFalse(app.hasEndorsed(1, SOLIDITY, 2));
        assertFalse(app.hasWalletEndorsed(1, SOLIDITY, bob));
        _register(1, "solidity");
        _endorse(2, 1, SOLIDITY);
        assertEq(app.getAgentSkills(1)[0].endorsements, 1);
    }

    function test_adminCannotRegisterHideOrEndorseForAnAgentsOwner() public {
        _register(1, "solidity");
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.NotAgentOwner.selector, 1));
        app.registerSkill(1, "research");
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.NotAgentOwner.selector, 1));
        app.hideSkill(1, SOLIDITY);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.NotAgentOwner.selector, 2));
        app.endorseSkill(2, 1, SOLIDITY);
        assertEq(app.getAgentSkills(1).length, 1);
        assertEq(app.getAgentSkills(1)[0].endorsements, 0);
        assertFalse(app.hasWalletEndorsed(1, SOLIDITY, address(this)));
    }

    function test_registrationFailureDoesNotCreateCatalogOrCandidateEntries() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.NotAgentOwner.selector, 1));
        app.registerSkill(1, "solidity");
        vm.prank(alice);
        vm.expectRevert(AgentSkill.InvalidSkill.selector);
        app.registerSkill(1, "bad_skill");
        assertEq(app.getAgentSkills(1).length, 0);
        assertEq(app.skillAgentCount(SOLIDITY), 0);
        (, uint256 total) = app.getSkills(0, 50);
        assertEq(total, 0);
        _register(1, "solidity");
        assertEq(app.skillAgentCount(SOLIDITY), 1);
    }

    function test_capCountsActiveSkillsOnlyAndReactivationNeverDuplicatesCandidates() public {
        bytes32[] memory skills = new bytes32[](32);
        for (uint256 i; i < 32; ++i) {
            skills[i] = _register(1, string.concat("skill ", vm.toString(i)));
        }
        vm.prank(alice);
        vm.expectRevert(AgentSkill.SkillLimitReached.selector);
        app.registerSkill(1, "new skill");
        // Exactly one slot is released per hidden skill, whichever position it held.
        _hide(1, skills[17]);
        bytes32 fresh = _register(1, "new skill");
        vm.prank(alice);
        vm.expectRevert(AgentSkill.SkillLimitReached.selector);
        app.registerSkill(1, "SKILL 17");
        assertEq(app.getAgentSkills(1).length, 32);
        assertEq(app.skillAgentCount(fresh), 1);
        // Hiding everything leaves 32 free slots; old labels and new labels both fit again.
        for (uint256 i; i < 32; ++i) {
            if (i != 17) _hide(1, skills[i]);
        }
        _hide(1, fresh);
        assertEq(app.getAgentSkills(1).length, 0);
        for (uint256 i; i < 32; ++i) {
            _register(1, string.concat("SKILL ", vm.toString(i)));
        }
        vm.prank(alice);
        vm.expectRevert(AgentSkill.SkillLimitReached.selector);
        app.registerSkill(1, "new skill");
        assertEq(app.getAgentSkills(1).length, 32);
        for (uint256 i; i < 32; ++i) {
            assertEq(app.skillAgentCount(skills[i]), 1, "reactivation duplicated a candidate");
        }
        (, uint256 total) = app.getSkills(0, 50);
        assertEq(total, 33);
    }

    function test_hidingSwapsTheLastSkillIntoTheGapAndReactivationAppends() public {
        _register(1, "writing");
        _register(1, "solidity");
        _register(1, "research");
        bytes32 writing = keccak256("writing");
        _endorse(2, 1, SOLIDITY);
        _endorse(2, 1, RESEARCH);
        _hide(1, SOLIDITY);
        AgentSkill.Skill[] memory skills = app.getAgentSkills(1);
        assertEq(skills.length, 2);
        assertEq(skills[0].id, writing);
        assertEq(skills[1].id, RESEARCH);
        assertEq(skills[1].endorsements, 1);
        _register(1, "solidity");
        skills = app.getAgentSkills(1);
        assertEq(skills.length, 3);
        assertEq(skills[0].id, writing);
        assertEq(skills[1].id, RESEARCH);
        assertEq(skills[2].id, SOLIDITY);
        assertEq(skills[2].endorsements, 1);
        // The moved skill's new position must be tracked: hiding it next must not corrupt the list.
        _hide(1, RESEARCH);
        skills = app.getAgentSkills(1);
        assertEq(skills.length, 2);
        assertEq(skills[0].id, writing);
        assertEq(skills[1].id, SOLIDITY);
        _hide(1, writing);
        skills = app.getAgentSkills(1);
        assertEq(skills.length, 1);
        assertEq(skills[0].id, SOLIDITY);
        assertEq(skills[0].endorsements, 1);
        _hide(1, SOLIDITY);
        assertEq(app.getAgentSkills(1).length, 0);
        vm.prank(alice);
        vm.expectRevert(AgentSkill.SkillNotActive.selector);
        app.hideSkill(1, SOLIDITY);
        // Endorsements of a hidden-then-reactivated skill still count and still reject the same voters.
        _register(1, "research");
        assertEq(app.getAgentSkills(1)[0].endorsements, 1);
        vm.prank(bob);
        vm.expectRevert(AgentSkill.DuplicateEndorsement.selector);
        app.endorseSkill(2, 1, RESEARCH);
    }

    /// @dev Random hide/reactivate sequences keep the active list a permutation of the model's active set.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_activeListIsAlwaysAPermutationOfTheActiveSet(uint8[24] memory steps) public {
        bytes32[8] memory ids;
        bool[8] memory active;
        bool[8] memory known;
        for (uint256 i; i < 8; ++i) {
            ids[i] = keccak256(bytes(string.concat("skill ", vm.toString(i))));
        }
        for (uint256 s; s < steps.length; ++s) {
            uint256 i = steps[s] % 8;
            if (active[i]) {
                _hide(1, ids[i]);
            } else {
                _register(1, string.concat("skill ", vm.toString(i)));
                known[i] = true;
            }
            active[i] = !active[i];
            AgentSkill.Skill[] memory listed = app.getAgentSkills(1);
            uint256 expected;
            for (uint256 k; k < 8; ++k) {
                if (!active[k]) continue;
                ++expected;
                uint256 seen;
                for (uint256 j; j < listed.length; ++j) {
                    if (listed[j].id == ids[k]) ++seen;
                }
                assertEq(seen, 1, "active skill missing or duplicated");
            }
            assertEq(listed.length, expected, "hidden skill still listed");
            for (uint256 k; k < 8; ++k) {
                assertEq(
                    app.skillAgentCount(ids[k]), known[k] ? 1 : 0, "candidate list changed by reactivation"
                );
            }
        }
    }

    function test_maximumIdentityAndZeroIdentityDoNotCollide() public {
        identity.setOwner(0, alice);
        identity.setOwner(type(uint256).max, bob);
        _register(0, "solidity");
        _register(type(uint256).max, "solidity");
        _endorse(type(uint256).max, 0, SOLIDITY);
        _endorse(0, type(uint256).max, SOLIDITY);
        assertEq(app.getAgentSkills(0)[0].endorsements, 1);
        assertEq(app.getAgentSkills(type(uint256).max)[0].endorsements, 1);
        (AgentSkill.RankedAgent[] memory ranked,,) = app.getTopAgents(SOLIDITY, 0, 50, 20);
        assertEq(ranked.length, 2);
        assertEq(ranked[0].agentId, 0);
        assertEq(ranked[1].agentId, type(uint256).max);
    }

    function test_maximumTrustSetAndMetricLengthsAreAcceptedAndOversizeIsAtomic() public {
        address[] memory clients = new address[](32);
        for (uint256 i; i < 32; ++i) {
            clients[i] = makeAddr(string.concat("publisher ", vm.toString(i)));
        }
        app.setTrustedClients(clients);
        assertEq(app.getTrustedClients(), clients);
        string memory maximum = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuv";
        app.setReputationMetric(maximum, maximum);
        uint64 version = app.policyVersion();
        vm.expectRevert(AgentSkill.InvalidPolicy.selector);
        app.setReputationMetric(string.concat(maximum, "x"), "");
        vm.expectRevert(AgentSkill.InvalidPolicy.selector);
        app.setReputationMetric("quality", string.concat(maximum, "x"));
        // Duplicate at the end must not partially replace the old policy.
        clients[31] = clients[0];
        vm.expectRevert(AgentSkill.InvalidPolicy.selector);
        app.setTrustedClients(clients);
        assertEq(app.policyVersion(), version);
        assertEq(app.reputationTag1(), maximum);
        assertEq(app.reputationTag2(), maximum);
        assertTrue(app.getTrustedClients()[31] != clients[0]);
    }

    function test_rejectedAdapterKeepsWorkingPolicyAndVersion() public {
        _register(1, "solidity");
        work.set(1, 20, 18);
        app.setWorkHistory(address(work));
        AgentSkill.ScoreBreakdown memory beforeScore = app.getScoreBreakdown(1, SOLIDITY);
        vm.mockCallRevert(address(work), abi.encodeWithSignature("identityRegistry()"), "adapter unavailable");
        vm.expectRevert(AgentSkill.InvalidPolicy.selector);
        app.setWorkHistory(address(work));
        assertEq(address(app.workHistory()), address(work));
        _assertSameScore(beforeScore, app.getScoreBreakdown(1, SOLIDITY));
    }

    function test_pendingOwnerHasNoAuthorityAndTransferCanBeReplacedOrCancelled() public {
        app.transferOwnership(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        app.setReputationMetric("quality", "audit");
        app.transferOwnership(carol);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        app.acceptOwnership();
        // OpenZeppelin's two-step zero transfer cancels a pending transfer, not current ownership.
        app.transferOwnership(address(0));
        assertEq(app.owner(), address(this));
        assertEq(app.pendingOwner(), address(0));
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        app.acceptOwnership();
        app.transferOwnership(carol);
        vm.prank(carol);
        app.acceptOwnership();
        vm.prank(carol);
        app.setReputationMetric("quality", "audit");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        app.setTrustedClients(_clients());
        vm.prank(carol);
        vm.expectRevert(AgentSkill.OwnershipRequired.selector);
        app.renounceOwnership();
    }

    function test_missingIdentityPreventsWritesAndRecoveryPreservesExistingState() public {
        _register(1, "solidity");
        bytes memory registryCode = IDENTITY.code;
        vm.etch(IDENTITY, "");
        bytes memory failure = abi.encodeWithSelector(AgentSkill.RegistryUnavailable.selector, IDENTITY);
        vm.expectRevert(failure);
        app.getAgentSkills(1);
        vm.prank(alice);
        vm.expectRevert(failure);
        app.hideSkill(1, SOLIDITY);
        vm.prank(bob);
        vm.expectRevert(failure);
        app.endorseSkill(2, 1, SOLIDITY);
        vm.etch(IDENTITY, registryCode);
        assertEq(app.getAgentSkills(1).length, 1);
        assertEq(app.getAgentSkills(1)[0].endorsements, 0);
        _endorse(2, 1, SOLIDITY);
        assertEq(app.getAgentSkills(1)[0].endorsements, 1);
    }

    function test_zeroOwnerResponseIsUnregisteredAcrossReadsAndWrites() public {
        vm.mockCall(IDENTITY, abi.encodeWithSignature("ownerOf(uint256)", 1), abi.encode(address(0)));
        bytes memory failure = abi.encodeWithSelector(AgentSkill.UnregisteredAgent.selector, 1);
        vm.expectRevert(failure);
        app.getAgentSkills(1);
        vm.expectRevert(failure);
        app.getScoreBreakdown(1, SOLIDITY);
        vm.prank(alice);
        vm.expectRevert(failure);
        app.registerSkill(1, "solidity");
        vm.prank(bob);
        vm.expectRevert(failure);
        app.endorseSkill(2, 1, SOLIDITY);
        assertFalse(app.hasEndorsed(1, SOLIDITY, 2));
    }

    function test_unknownAndHiddenSkillScoresFailBeforeQueryingEvidence() public {
        reputation.setFailure(true);
        vm.expectRevert(AgentSkill.SkillNotActive.selector);
        app.getScoreBreakdown(1, SOLIDITY);
        _register(1, "solidity");
        _hide(1, SOLIDITY);
        vm.expectRevert(AgentSkill.SkillNotActive.selector);
        app.getScoreBreakdown(1, SOLIDITY);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.UnregisteredAgent.selector, 999));
        app.getScoreBreakdown(999, SOLIDITY);
        assertEq(app.getAgentSkills(1).length, 0);
        assertEq(app.skillAgentCount(SOLIDITY), 1);
    }

    function test_valueAttachedToValidMutationRevertsWithoutChangingState() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) =
            address(app).call{value: 1}(abi.encodeCall(AgentSkill.registerSkill, (1, "solidity")));
        assertFalse(success);
        assertEq(address(app).balance, 0);
        assertEq(app.getAgentSkills(1).length, 0);
        _register(1, "solidity");
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (success,) = address(app).call{value: 1}(abi.encodeCall(AgentSkill.endorseSkill, (2, 1, SOLIDITY)));
        assertFalse(success);
        assertEq(app.getAgentSkills(1)[0].endorsements, 0);
        assertFalse(app.hasEndorsed(1, SOLIDITY, 2));
    }
}
