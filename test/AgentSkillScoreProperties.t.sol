// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AgentSkillFixture} from "./helpers/AgentSkillFixture.sol";
import {AgentSkill} from "src/AgentSkill.sol";

/// @dev Metamorphic properties constrain ranking incentives without copying the production formula.
contract AgentSkillScorePropertiesTest is AgentSkillFixture {
    function setUp() public override {
        super.setUp();
        _register(1, "solidity");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_equivalentDecimalRepresentationsHaveIdenticalPoints(
        uint16 ratingSeed,
        uint8 decimalsSeed,
        uint64 count
    ) public {
        uint256 cents = bound(ratingSeed, 0, 10_000);
        uint8 decimals = uint8(bound(decimalsSeed, 2, 18));
        _summary(1, count, int128(int256(cents)), 2);
        AgentSkill.ScoreBreakdown memory beforeScore = app.getScoreBreakdown(1, SOLIDITY);
        _summary(1, count, int128(int256(cents * 10 ** (decimals - 2))), decimals);
        AgentSkill.ScoreBreakdown memory afterScore = app.getScoreBreakdown(1, SOLIDITY);
        assertEq(afterScore.reputationBps, beforeScore.reputationBps);
        assertEq(afterScore.reputationPoints, beforeScore.reputationPoints);
        assertEq(afterScore.historyBps, beforeScore.historyBps);
        assertEq(afterScore.total, beforeScore.total);
        assertEq(afterScore.reputationDecimals, decimals);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_increasingRatingNeverLowersScore(uint16 lowSeed, uint16 highSeed, uint64 countSeed)
        public
    {
        uint64 count = uint64(bound(countSeed, 1, type(uint64).max));
        int128 lower = int128(int256(bound(lowSeed, 0, 10_000)));
        int128 higher = int128(int256(bound(highSeed, uint128(lower), 10_000)));
        _summary(1, count, lower, 2);
        AgentSkill.ScoreBreakdown memory beforeScore = app.getScoreBreakdown(1, SOLIDITY);
        _summary(1, count, higher, 2);
        AgentSkill.ScoreBreakdown memory afterScore = app.getScoreBreakdown(1, SOLIDITY);
        assertGe(afterScore.reputationPoints, beforeScore.reputationPoints);
        assertGe(afterScore.historyPoints, beforeScore.historyPoints);
        assertGe(afterScore.total, beforeScore.total);
        assertEq(afterScore.endorsementPoints, beforeScore.endorsementPoints);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_moreEqualQualityEvidenceDoesNotReduceScore(
        uint64 lowSeed,
        uint64 highSeed,
        uint16 ratingSeed
    ) public {
        uint64 lower = uint64(bound(lowSeed, 1, type(uint64).max));
        uint64 higher = uint64(bound(highSeed, lower, type(uint64).max));
        int128 rating = int128(int256(bound(ratingSeed, 1, 10_000)));
        _summary(1, lower, rating, 2);
        AgentSkill.ScoreBreakdown memory beforeScore = app.getScoreBreakdown(1, SOLIDITY);
        _summary(1, higher, rating, 2);
        AgentSkill.ScoreBreakdown memory afterScore = app.getScoreBreakdown(1, SOLIDITY);
        assertEq(afterScore.reputationPoints, beforeScore.reputationPoints);
        assertGe(afterScore.historyPoints, beforeScore.historyPoints);
        assertGe(afterScore.total, beforeScore.total);
        if (lower >= 20) assertEq(afterScore.total, beforeScore.total);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_additionalAcceptedWorkNeverReducesHistory(
        uint64 completedSeed,
        uint64 acceptedSeed,
        uint64 addedSeed
    ) public {
        uint64 completed = uint64(bound(completedSeed, 0, type(uint64).max - 1));
        uint64 accepted = uint64(bound(acceptedSeed, 0, completed));
        uint64 added = uint64(bound(addedSeed, 1, type(uint64).max - completed));
        app.setWorkHistory(address(work));
        _summary(1, 20, 83, 0);
        _endorse(2, 1, SOLIDITY);
        work.set(1, completed, accepted);
        AgentSkill.ScoreBreakdown memory beforeScore = app.getScoreBreakdown(1, SOLIDITY);
        work.set(1, completed + added, accepted + added);
        AgentSkill.ScoreBreakdown memory afterScore = app.getScoreBreakdown(1, SOLIDITY);
        assertGe(afterScore.historyBps, beforeScore.historyBps);
        assertGe(afterScore.total, beforeScore.total);
        assertEq(afterScore.reputationPoints, beforeScore.reputationPoints);
        assertEq(afterScore.endorsementPoints, beforeScore.endorsementPoints);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_additionalRejectedWorkCannotImproveHistory(
        uint64 completedSeed,
        uint64 acceptedSeed,
        uint64 rejectedSeed
    ) public {
        uint64 completed = uint64(bound(completedSeed, 0, type(uint64).max - 1));
        uint64 accepted = uint64(bound(acceptedSeed, 0, completed));
        uint64 rejected = uint64(bound(rejectedSeed, 1, type(uint64).max - completed));
        app.setWorkHistory(address(work));
        work.set(1, completed, accepted);
        AgentSkill.ScoreBreakdown memory beforeScore = app.getScoreBreakdown(1, SOLIDITY);
        work.set(1, completed + rejected, accepted);
        AgentSkill.ScoreBreakdown memory afterScore = app.getScoreBreakdown(1, SOLIDITY);
        assertLe(afterScore.historyBps, beforeScore.historyBps);
        assertLe(afterScore.historyPoints, beforeScore.historyPoints);
        assertLe(afterScore.total, beforeScore.total);
    }

    function test_workConfidenceThresholdAndUint64Extremes() public {
        app.setWorkHistory(address(work));
        uint64[7] memory completed = [uint64(0), 1, 19, 20, 21, type(uint64).max - 1, type(uint64).max];
        uint256[7] memory expected = [uint256(0), 500, 9500, 10_000, 10_000, 10_000, 10_000];
        for (uint256 i; i < completed.length; ++i) {
            work.set(1, completed[i], completed[i]);
            AgentSkill.ScoreBreakdown memory score = app.getScoreBreakdown(1, SOLIDITY);
            assertEq(score.historyBps, expected[i]);
            assertEq(score.completedWork, completed[i]);
            assertEq(score.acceptedWork, completed[i]);
            work.set(1, completed[i], 0);
            assertEq(app.getScoreBreakdown(1, SOLIDITY).historyBps, 0);
        }
        work.set(1, 21, 20);
        assertEq(app.getScoreBreakdown(1, SOLIDITY).historyBps, 9523);
        work.set(1, type(uint64).max, type(uint64).max - 1);
        assertEq(app.getScoreBreakdown(1, SOLIDITY).historyBps, 9999);
    }

    function test_negativeReputationDoesNotEraseValidWorkOrEndorsements() public {
        _summary(1, type(uint64).max, type(int128).min, 18);
        work.set(1, 20, 20);
        app.setWorkHistory(address(work));
        _endorse(2, 1, SOLIDITY);
        AgentSkill.ScoreBreakdown memory score = app.getScoreBreakdown(1, SOLIDITY);
        assertEq(score.reputationPoints, 0);
        assertEq(score.reputationValue, type(int128).min);
        assertEq(score.historyPoints, 2500);
        assertEq(score.endorsementPoints, 75);
        assertEq(score.total, 2575);
    }

    function test_workEvidenceExistsBeforeFirstSkillRegistrationWithoutAnyFeedback() public {
        work.set(2, 20, 20);
        app.setWorkHistory(address(work));
        _register(2, "solidity");
        AgentSkill.ScoreBreakdown memory score = app.getScoreBreakdown(2, SOLIDITY);
        assertEq(score.feedbackCount, 0);
        assertEq(score.endorsements, 0);
        assertEq(score.historySource, 1);
        assertEq(score.total, 2500);
        (AgentSkill.RankedAgent[] memory ranked,,) = app.getTopAgents(SOLIDITY, 0, 50, 20);
        assertEq(ranked[0].agentId, 2);
        assertGt(ranked[0].score.total, ranked[1].score.total);
    }

    function test_endorsementCapBoundsPointsButDoesNotDiscardCountOrVotes() public {
        _summary(1, 20, 100, 0);
        work.set(1, 20, 20);
        app.setWorkHistory(address(work));
        for (uint256 i; i < 22; ++i) {
            uint256 id = 100 + i;
            identity.setOwner(id, makeAddr(string.concat("cap voter ", vm.toString(i))));
            _endorse(id, 1, SOLIDITY);
            AgentSkill.ScoreBreakdown memory score = app.getScoreBreakdown(1, SOLIDITY);
            assertEq(score.endorsements, i + 1);
            assertEq(score.reputationPoints, 6000);
            assertEq(score.historyPoints, 2500);
            if (i < 20) assertEq(score.endorsementPoints, (i + 1) * 75);
            else assertEq(score.total, 10_000);
        }
        assertEq(app.getAgentSkills(1)[0].endorsements, 22);
        assertTrue(app.hasEndorsed(1, SOLIDITY, 121));
        _hide(1, SOLIDITY);
        _register(1, "SOLIDITY");
        assertEq(app.getScoreBreakdown(1, SOLIDITY).endorsements, 22);
        assertEq(app.getScoreBreakdown(1, SOLIDITY).total, 10_000);
    }

    function test_reputationAndWorkAreSharedBySkillsButEndorsementsAreNot() public {
        _register(1, "research");
        _summary(1, 20, 87, 0);
        work.set(1, 24, 18);
        app.setWorkHistory(address(work));
        _endorse(2, 1, SOLIDITY);
        AgentSkill.ScoreBreakdown memory solidityScore = app.getScoreBreakdown(1, SOLIDITY);
        AgentSkill.ScoreBreakdown memory researchScore = app.getScoreBreakdown(1, RESEARCH);
        assertEq(solidityScore.reputationPoints, researchScore.reputationPoints);
        assertEq(solidityScore.historyPoints, researchScore.historyPoints);
        assertEq(solidityScore.total - researchScore.total, 75);
        assertEq(researchScore.endorsements, 0);
    }

    function test_publisherReplacementAndPermutationUseCurrentPolicy() public {
        reputation.add(1, publisher, 20, 0, "starred", "");
        reputation.add(1, carol, 100, 0, "starred", "");
        assertEq(app.getScoreBreakdown(1, SOLIDITY).reputationBps, 2000);
        address[] memory clients = new address[](1);
        clients[0] = carol;
        app.setTrustedClients(clients);
        assertEq(app.getScoreBreakdown(1, SOLIDITY).reputationBps, 10_000);
        clients = new address[](2);
        clients[0] = publisher;
        clients[1] = carol;
        app.setTrustedClients(clients);
        AgentSkill.ScoreBreakdown memory beforeScore = app.getScoreBreakdown(1, SOLIDITY);
        assertEq(beforeScore.reputationBps, 6000);
        assertEq(beforeScore.feedbackCount, 2);
        clients[0] = carol;
        clients[1] = publisher;
        app.setTrustedClients(clients);
        AgentSkill.ScoreBreakdown memory afterScore = app.getScoreBreakdown(1, SOLIDITY);
        assertEq(afterScore.policyVersion, beforeScore.policyVersion + 1);
        afterScore.policyVersion = beforeScore.policyVersion;
        _assertSameScore(beforeScore, afterScore);
    }

    function test_skillsAndVotesSurvivePolicyChangesAndAgentTransfer() public {
        _summary(1, 20, 90, 0);
        _endorse(2, 1, SOLIDITY);
        AgentSkill.ScoreBreakdown memory beforeScore = app.getScoreBreakdown(1, SOLIDITY);
        identity.setOwner(1, carol);
        _assertSameScore(beforeScore, app.getScoreBreakdown(1, SOLIDITY));
        work.set(1, 100, 10);
        app.setWorkHistory(address(work));
        AgentSkill.ScoreBreakdown memory afterScore = app.getScoreBreakdown(1, SOLIDITY);
        assertEq(afterScore.endorsements, 1);
        assertEq(afterScore.reputationPoints, beforeScore.reputationPoints);
        assertLt(afterScore.total, beforeScore.total);
        assertEq(app.getAgentSkills(1)[0].endorsements, 1);
        assertTrue(app.hasEndorsed(1, SOLIDITY, 2));
        assertTrue(app.hasWalletEndorsed(1, SOLIDITY, bob));
    }

    function test_allUnsupportedDecimalPrecisionsFailWithoutLosingSkillState() public {
        for (uint256 decimals = 19; decimals <= 255; ++decimals) {
            _summary(1, 20, 100, uint8(decimals));
            vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, REPUTATION, 1));
            app.getScoreBreakdown(1, SOLIDITY);
        }
        _summary(1, 20, 100, 0);
        assertEq(app.getScoreBreakdown(1, SOLIDITY).total, 8500);
        assertEq(app.getAgentSkills(1).length, 1);
    }
}
