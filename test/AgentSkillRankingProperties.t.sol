// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AgentSkillFixture} from "./helpers/AgentSkillFixture.sol";
import {AgentSkill} from "src/AgentSkill.sol";
import {IReputationRegistry} from "src/interfaces/IReputationRegistry.sol";

contract AgentSkillRankingPropertiesTest is AgentSkillFixture {
    struct Candidate {
        uint256 id;
        uint256 points;
        bool active;
    }

    /// @dev Pairwise rank counting is independent of the contract's insertion-sort implementation.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_everyReturnedSlotIsTheCorrectTopCandidate(
        uint8[12] memory ratings,
        uint16 hiddenMask,
        uint8 offsetSeed,
        uint8 scanSeed,
        uint8 resultSeed
    ) public {
        Candidate[] memory candidates = new Candidate[](12);
        for (uint256 i; i < candidates.length; ++i) {
            // Include the full uint256 endpoints and register in non-numeric order.
            uint256 id = i == 0 ? type(uint256).max : i == 1 ? 0 : 12 - i;
            identity.setOwner(id, alice);
            _register(id, "solidity");
            // Six possible integer ratings deliberately make score ties common.
            uint256 rating = bound(ratings[i], 0, 5) * 20;
            _summary(id, 20, int128(int256(rating)), 0);
            bool active = uint256(hiddenMask) & (uint256(1) << i) == 0;
            if (!active) _hide(id, SOLIDITY);
            // At full historical confidence with no endorsements, 100 rating points earn 8,500 points.
            candidates[i] = Candidate(id, rating * 85, active);
        }
        uint256 offset = bound(offsetSeed, 0, candidates.length);
        uint256 scan = bound(scanSeed, 1, 50);
        uint256 results = bound(resultSeed, 1, scan < 20 ? scan : 20);
        _assertWindow(candidates, offset, scan, results);
        // Always check a nonempty candidate window too, even if the fuzzed cursor was terminal.
        _assertWindow(candidates, 0, 50, 3);
    }

    function test_allTiesRetainSmallestIdsWhenTopKIsFull() public {
        Candidate[] memory candidates = new Candidate[](25);
        for (uint256 i; i < candidates.length; ++i) {
            uint256 id = i == 0 ? type(uint256).max : 24 - i;
            identity.setOwner(id, alice);
            _register(id, "solidity");
            candidates[i] = Candidate(id, 0, true);
        }
        _assertWindow(candidates, 0, 50, 1);
        _assertWindow(candidates, 0, 50, 20);
    }

    function test_threePagesAdvanceExactlyAndIncludeLateHighestRankedAgents() public {
        Candidate[] memory candidates = new Candidate[](101);
        for (uint256 i; i < candidates.length; ++i) {
            uint256 id = 100 - i;
            identity.setOwner(id, alice);
            _register(id, "solidity");
            _summary(id, 20, int128(int256(i)), 0);
            candidates[i] = Candidate(id, i * 85, true);
        }
        _assertWindow(candidates, 0, 50, 20);
        _assertWindow(candidates, 50, 50, 20);
        _assertWindow(candidates, 100, 50, 20);
        _assertWindow(candidates, 101, 50, 20);
        (AgentSkill.RankedAgent[] memory last, uint256 next, uint256 total) =
            app.getTopAgents(SOLIDITY, 100, 50, 20);
        assertEq(last.length, 1);
        assertEq(last[0].agentId, 0);
        assertEq(last[0].score.total, 8500);
        assertEq(next, 101);
        assertEq(total, 101);
    }

    function test_entireHiddenPageStillAdvancesAndDoesNotQueryHiddenScores() public {
        for (uint256 i; i < 51; ++i) {
            identity.setOwner(i, alice);
            _register(i, "solidity");
            if (i < 50) {
                _hide(i, SOLIDITY);
                vm.mockCallRevert(
                    REPUTATION,
                    abi.encodeCall(IReputationRegistry.getSummary, (i, _clients(), "starred", "")),
                    "hidden source should not be queried"
                );
            }
        }
        (AgentSkill.RankedAgent[] memory ranked, uint256 next, uint256 total) =
            app.getTopAgents(SOLIDITY, 0, 50, 20);
        assertEq(ranked.length, 0);
        assertEq(next, 50);
        assertEq(total, 51);
        (ranked, next, total) = app.getTopAgents(SOLIDITY, next, 50, 20);
        assertEq(ranked.length, 1);
        assertEq(ranked[0].agentId, 50);
        assertEq(next, 51);
        assertEq(total, 51);
    }

    function test_workFailureInLowRankedCandidateStillRejectsTheWholePage() public {
        _register(1, "solidity");
        _register(2, "solidity");
        _summary(1, 20, 100, 0);
        _summary(2, 0, 0, 0);
        app.setWorkHistory(address(work));
        work.set(1, 20, 20);
        work.set(2, 0, 1);
        // The first candidate already fills top 1, but returning it without checking candidate 2 is unsound.
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, address(work), 2));
        app.getTopAgents(SOLIDITY, 0, 50, 1);
        assertEq(app.getScoreBreakdown(1, SOLIDITY).total, 8500);
    }

    function test_failedCandidateOutsideTheWindowDoesNotBlockOtherPages() public {
        _register(1, "solidity");
        _register(2, "solidity");
        _summary(1, 20, 100, 0);
        vm.mockCallRevert(
            REPUTATION,
            abi.encodeCall(IReputationRegistry.getSummary, (2, _clients(), "starred", "")),
            "unavailable"
        );
        (AgentSkill.RankedAgent[] memory first, uint256 next,) = app.getTopAgents(SOLIDITY, 0, 1, 1);
        assertEq(first.length, 1);
        assertEq(first[0].agentId, 1);
        assertEq(next, 1);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, REPUTATION, 2));
        app.getTopAgents(SOLIDITY, next, 1, 1);
    }

    function test_liveReputationRevocationReordersLeaderboard() public {
        _register(1, "solidity");
        _register(2, "solidity");
        reputation.add(1, publisher, 100, 0, "starred", "");
        reputation.add(2, publisher, 50, 0, "starred", "");
        (AgentSkill.RankedAgent[] memory beforeRank,,) = app.getTopAgents(SOLIDITY, 0, 50, 20);
        assertEq(beforeRank[0].agentId, 1);
        reputation.revoke(1, 0);
        (AgentSkill.RankedAgent[] memory afterRank,,) = app.getTopAgents(SOLIDITY, 0, 50, 20);
        assertEq(afterRank[0].agentId, 2);
        assertEq(afterRank[1].agentId, 1);
        assertEq(afterRank[1].score.total, 0);
        _assertSameScore(afterRank[0].score, app.getScoreBreakdown(2, SOLIDITY));
    }

    function test_endorsementsAndWorkCanChangeRankingAtConstantReputation() public {
        _register(1, "solidity");
        _register(2, "solidity");
        _summary(1, 20, 80, 0);
        _summary(2, 20, 80, 0);
        (AgentSkill.RankedAgent[] memory ranked,,) = app.getTopAgents(SOLIDITY, 0, 50, 20);
        assertEq(ranked[0].agentId, 1);
        _endorse(3, 2, SOLIDITY);
        (ranked,,) = app.getTopAgents(SOLIDITY, 0, 50, 20);
        assertEq(ranked[0].agentId, 2);
        work.set(1, 20, 20);
        work.set(2, 20, 0);
        app.setWorkHistory(address(work));
        (ranked,,) = app.getTopAgents(SOLIDITY, 0, 50, 20);
        assertEq(ranked[0].agentId, 1);
        assertEq(ranked[1].score.endorsements, 1);
    }

    function test_catalogPaginationIncludesHiddenSkillsOnceAndNoPairEndorsements() public {
        bytes32[] memory ids = new bytes32[](60);
        for (uint256 i; i < ids.length; ++i) {
            uint256 agent = i < 30 ? 1 : 2;
            ids[i] = _register(agent, string.concat("catalog ", vm.toString(i)));
            if (i % 2 == 0) _hide(agent, ids[i]);
        }
        // A second agent advertising the same skill must not duplicate the catalog entry.
        _register(3, "catalog 1");
        _endorse(2, 1, ids[1]);
        (AgentSkill.Skill[] memory first, uint256 total) = app.getSkills(0, 50);
        assertEq(total, 60);
        assertEq(first.length, 50);
        for (uint256 i; i < first.length; ++i) {
            assertEq(first[i].id, ids[i]);
            assertEq(first[i].endorsements, 0);
        }
        (AgentSkill.Skill[] memory last,) = app.getSkills(50, 50);
        assertEq(last.length, 10);
        for (uint256 i; i < last.length; ++i) {
            assertEq(last[i].id, ids[50 + i]);
        }
        (last,) = app.getSkills(60, 1);
        assertEq(last.length, 0);
        assertEq(app.skillAgentCount(ids[1]), 2);
    }

    function test_extremePaginationInputsReturnInvalidPageInsteadOfArithmeticPanic() public {
        _register(1, "solidity");
        uint256 maximum = type(uint256).max;
        vm.expectRevert(AgentSkill.InvalidPage.selector);
        app.getTopAgents(SOLIDITY, maximum, 50, 20);
        vm.expectRevert(AgentSkill.InvalidPage.selector);
        app.getTopAgents(SOLIDITY, 0, maximum, 20);
        vm.expectRevert(AgentSkill.InvalidPage.selector);
        app.getTopAgents(SOLIDITY, 0, 50, maximum);
        vm.expectRevert(AgentSkill.InvalidPage.selector);
        app.getTopAgents(SOLIDITY, 0, 50, 0);
        vm.expectRevert(AgentSkill.InvalidPage.selector);
        app.getTopAgents(SOLIDITY, 0, 1, 2);
        vm.expectRevert(AgentSkill.InvalidPage.selector);
        app.getSkills(0, maximum);
    }

    function _assertWindow(Candidate[] memory candidates, uint256 offset, uint256 scan, uint256 resultLimit)
        internal
        view
    {
        (AgentSkill.RankedAgent[] memory ranked, uint256 next, uint256 total) =
            app.getTopAgents(SOLIDITY, offset, scan, resultLimit);
        uint256 end = offset + scan;
        if (end > candidates.length) end = candidates.length;
        assertEq(next, end);
        assertEq(total, candidates.length);
        uint256 activeCount;
        for (uint256 i = offset; i < end; ++i) {
            if (candidates[i].active) ++activeCount;
        }
        assertEq(ranked.length, activeCount < resultLimit ? activeCount : resultLimit);
        for (uint256 i = offset; i < end; ++i) {
            if (!candidates[i].active) continue;
            uint256 better;
            for (uint256 j = offset; j < end; ++j) {
                if (!candidates[j].active) continue;
                if (
                    candidates[j].points > candidates[i].points
                        || (candidates[j].points == candidates[i].points
                            && candidates[j].id < candidates[i].id)
                ) ++better;
            }
            if (better < ranked.length) {
                assertEq(ranked[better].agentId, candidates[i].id, "wrong candidate at pairwise rank");
                assertEq(ranked[better].score.total, candidates[i].points, "wrong weighted score");
                _assertSameScore(ranked[better].score, app.getScoreBreakdown(candidates[i].id, SOLIDITY));
            }
        }
    }
}
