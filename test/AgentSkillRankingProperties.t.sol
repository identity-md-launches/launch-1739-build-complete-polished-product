// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AgentSkillFixture} from "./helpers/AgentSkillFixture.sol";
import {AgentSkill} from "src/AgentSkill.sol";
import {IReputationRegistry} from "src/interfaces/IReputationRegistry.sol";
import {MockWorkHistory} from "./mocks/MockWorkHistory.sol";

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
                // Matches the live policy (default match-all tags), so a query for a hidden agent would fail loudly.
                _failSummary(i);
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

    function test_workFailureInLowRankedCandidateIsReportedAfterTheTopListNotScoredAsZero() public {
        _register(1, "solidity");
        _register(2, "solidity");
        _summary(1, 20, 100, 0);
        _summary(2, 0, 0, 0);
        app.setWorkHistory(address(work));
        work.set(1, 20, 20);
        work.set(2, 0, 1);
        // The first candidate fills top 1; the invalid work answer for candidate 2 is still surfaced.
        (AgentSkill.RankedAgent[] memory ranked, uint256 next, uint256 total) =
            app.getTopAgents(SOLIDITY, 0, 50, 1);
        assertEq(next, 2);
        assertEq(total, 2);
        assertEq(ranked.length, 2);
        assertEq(ranked[0].agentId, 1);
        assertFalse(ranked[0].unavailable);
        assertEq(ranked[0].unavailableSource, address(0));
        assertEq(ranked[0].score.total, 8500);
        assertEq(ranked[1].agentId, 2);
        assertTrue(ranked[1].unavailable);
        assertEq(ranked[1].unavailableSource, address(work));
        _assertSameScore(ranked[1].score, _emptyScore());
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, address(work), 2));
        app.getScoreBreakdown(2, SOLIDITY);
        assertEq(app.getScoreBreakdown(1, SOLIDITY).total, 8500);
        // A repaired source is scored again on the next read without any state change in AgentSkill.
        work.set(2, 1, 1);
        (ranked,,) = app.getTopAgents(SOLIDITY, 0, 50, 1);
        assertEq(ranked.length, 1);
        assertEq(ranked[0].agentId, 1);
        assertEq(app.getScoreBreakdown(2, SOLIDITY).historyBps, 500);
    }

    function test_failedCandidateOutsideTheWindowIsReportedOnlyOnItsOwnPage() public {
        _register(1, "solidity");
        _register(2, "solidity");
        _summary(1, 20, 100, 0);
        _failSummary(2);
        (AgentSkill.RankedAgent[] memory first, uint256 next,) = app.getTopAgents(SOLIDITY, 0, 1, 1);
        assertEq(first.length, 1);
        assertEq(first[0].agentId, 1);
        assertFalse(first[0].unavailable);
        assertEq(next, 1);
        (AgentSkill.RankedAgent[] memory second, uint256 last, uint256 total) =
            app.getTopAgents(SOLIDITY, next, 1, 1);
        assertEq(last, 2);
        assertEq(total, 2);
        assertEq(second.length, 1);
        assertEq(second[0].agentId, 2);
        assertTrue(second[0].unavailable);
        assertEq(second[0].unavailableSource, REPUTATION);
        assertEq(second[0].score.policyVersion, 0);
        assertEq(second[0].score.total, 0);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, REPUTATION, 2));
        app.getScoreBreakdown(2, SOLIDITY);
    }

    /// @dev The scored prefix ranks only readable candidates; every unreadable active candidate follows it
    /// once, in scan order, naming the first source that failed and carrying no partial figures.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unreadableCandidatesTrailTheScoredListWithoutHidingIt(
        uint8[8] memory ratings,
        uint8 hiddenMask,
        uint8 reputationFailMask,
        uint8 workFailMask,
        uint8 resultSeed
    ) public {
        app.setWorkHistory(address(work));
        Candidate[] memory candidates = new Candidate[](8);
        uint256[] memory failing = new uint256[](8);
        address[] memory failedSource = new address[](8);
        uint256 failures;
        for (uint256 i; i < candidates.length; ++i) {
            uint256 id = i + 1;
            identity.setOwner(id, alice);
            _register(id, "solidity");
            uint256 rating = bound(ratings[i], 0, 5) * 20;
            work.set(id, 20, 20);
            bool reputationFails = uint256(reputationFailMask) & (uint256(1) << i) != 0;
            bool workFails = uint256(workFailMask) & (uint256(1) << i) != 0;
            if (reputationFails) _failSummary(id);
            else _summary(id, 20, int128(int256(rating)), 0);
            if (workFails) {
                vm.mockCallRevert(
                    address(work), abi.encodeCall(MockWorkHistory.getWorkSummary, (id)), "ledger down"
                );
            }
            bool active = uint256(hiddenMask) & (uint256(1) << i) == 0;
            if (!active) _hide(id, SOLIDITY);
            // Full reputation and full accepted-work history: 100 rating points earn 6,000 + 2,500 points.
            candidates[i] = Candidate(id, rating * 60 + 2500, active && !reputationFails && !workFails);
            if (active && (reputationFails || workFails)) {
                failing[failures] = id;
                failedSource[failures++] = reputationFails ? REPUTATION : address(work);
            }
        }
        uint256 results = bound(resultSeed, 1, 20);
        (AgentSkill.RankedAgent[] memory ranked, uint256 next, uint256 total) =
            app.getTopAgents(SOLIDITY, 0, 50, results);
        assertEq(next, 8);
        assertEq(total, 8);
        uint256 readable;
        for (uint256 i; i < candidates.length; ++i) {
            if (candidates[i].active) ++readable;
        }
        uint256 scored = readable < results ? readable : results;
        assertEq(ranked.length, scored + failures, "unreadable candidates must not change the scored count");
        for (uint256 i; i < scored; ++i) {
            assertFalse(ranked[i].unavailable);
            assertEq(ranked[i].unavailableSource, address(0));
            if (i != 0) {
                assertTrue(
                    ranked[i - 1].score.total > ranked[i].score.total
                        || (ranked[i - 1].score.total == ranked[i].score.total
                            && ranked[i - 1].agentId < ranked[i].agentId),
                    "scored prefix is not in descending order"
                );
            }
            _assertSameScore(ranked[i].score, app.getScoreBreakdown(ranked[i].agentId, SOLIDITY));
        }
        // Pairwise oracle over readable candidates only.
        for (uint256 i; i < candidates.length; ++i) {
            if (!candidates[i].active) continue;
            uint256 better;
            for (uint256 j; j < candidates.length; ++j) {
                if (!candidates[j].active) continue;
                if (
                    candidates[j].points > candidates[i].points
                        || (candidates[j].points == candidates[i].points
                            && candidates[j].id < candidates[i].id)
                ) ++better;
            }
            if (better < scored) {
                assertEq(ranked[better].agentId, candidates[i].id, "wrong readable candidate at rank");
                assertEq(ranked[better].score.total, candidates[i].points);
            }
        }
        for (uint256 i; i < failures; ++i) {
            AgentSkill.RankedAgent memory entry = ranked[scored + i];
            assertEq(entry.agentId, failing[i], "unreadable candidates must keep scan order");
            assertTrue(entry.unavailable);
            assertEq(entry.unavailableSource, failedSource[i]);
            _assertSameScore(entry.score, _emptyScore());
            vm.expectRevert(
                abi.encodeWithSelector(
                    AgentSkill.ScoreSourceUnavailable.selector, failedSource[i], failing[i]
                )
            );
            app.getScoreBreakdown(failing[i], SOLIDITY);
        }
    }

    function _failSummary(uint256 id) internal {
        vm.mockCallRevert(
            REPUTATION,
            abi.encodeCall(
                IReputationRegistry.getSummary,
                (id, app.getTrustedClients(), app.reputationTag1(), app.reputationTag2())
            ),
            "unavailable"
        );
    }

    function _emptyScore() internal pure returns (AgentSkill.ScoreBreakdown memory score) {}

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
                assertFalse(ranked[better].unavailable, "readable candidate flagged unavailable");
                assertEq(ranked[better].unavailableSource, address(0));
                _assertSameScore(ranked[better].score, app.getScoreBreakdown(candidates[i].id, SOLIDITY));
            }
        }
    }
}
