// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentSkill} from "../src/AgentSkill.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockReputationRegistry} from "./mocks/MockReputationRegistry.sol";
import {MockWorkHistory} from "./mocks/MockWorkHistory.sol";

contract AgentSkillTest is Test {
    address internal constant IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant REPUTATION = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
    address internal constant LAUNCH_OWNER = 0x7F4b7860bA9957128c5Ce416e94784cA98b5C976;
    AgentSkill internal app;
    MockIdentityRegistry internal identity;
    MockReputationRegistry internal reputation;
    MockWorkHistory internal work;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal publisher;
    bytes32 internal solidityId;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        publisher = makeAddr("publisher");
        vm.etch(IDENTITY, address(new MockIdentityRegistry()).code);
        vm.etch(REPUTATION, address(new MockReputationRegistry()).code);
        identity = MockIdentityRegistry(IDENTITY);
        reputation = MockReputationRegistry(REPUTATION);
        work = new MockWorkHistory();
        app = new AgentSkill(LAUNCH_OWNER);
        identity.setOwner(1, alice);
        identity.setOwner(2, bob);
        identity.setOwner(3, carol);
        address[] memory clients = new address[](1);
        clients[0] = publisher;
        vm.prank(LAUNCH_OWNER);
        app.setTrustedClients(clients);
        vm.prank(alice);
        solidityId = app.registerSkill(1, "Solidity");
    }

    function test_constructorWorksWithoutDependenciesAndDoesNotUseFactoryOwner() public {
        vm.etch(IDENTITY, "");
        vm.etch(REPUTATION, "");
        vm.prank(makeAddr("factory"));
        AgentSkill deployed = new AgentSkill(LAUNCH_OWNER);
        assertEq(deployed.owner(), LAUNCH_OWNER);
        assertEq(address(deployed.IDENTITY_REGISTRY()), IDENTITY);
        assertEq(address(deployed.REPUTATION_REGISTRY()), REPUTATION);
        assertEq(deployed.getTrustedClients().length, 0);
        assertEq(address(deployed.workHistory()), address(0));
        assertLe(address(deployed).code.length, 24_576);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.RegistryUnavailable.selector, IDENTITY));
        deployed.registerSkill(1, "Solidity");
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AgentSkill(address(0));
    }

    function test_registrationUsesCurrentOwnerAndCanonicalLabel() public {
        vm.prank(alice);
        bytes32 id = app.registerSkill(1, "  Security   Audit  ");
        assertEq(id, keccak256("security audit"));
        AgentSkill.Skill[] memory skills = app.getAgentSkills(1);
        assertEq(skills.length, 2);
        assertEq(skills[1].name, "security audit");
        vm.prank(alice);
        vm.expectRevert(AgentSkill.SkillAlreadyActive.selector);
        app.registerSkill(1, "SECURITY AUDIT");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.NotAgentOwner.selector, 1));
        app.registerSkill(1, "writing");
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.UnregisteredAgent.selector, 999));
        app.registerSkill(999, "writing");
    }

    function test_tokenIdZeroIsValidIfRegistered() public {
        identity.setOwner(0, alice);
        vm.prank(alice);
        app.registerSkill(0, "research");
        assertEq(app.getAgentSkills(0).length, 1);
    }

    function test_transferMovesManagementAndPreservesSkills() public {
        identity.setOwner(1, bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.NotAgentOwner.selector, 1));
        app.hideSkill(1, solidityId);
        vm.prank(bob);
        app.registerSkill(1, "Research");
        assertEq(app.getAgentSkills(1).length, 2);
    }

    function test_invalidNamesAndBoundaries() public {
        string[8] memory invalid =
            ["", " ", "---", "\tSolidity", "a\nb", "skill<script>", "ui_ux", unicode"é"];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(AgentSkill.InvalidSkill.selector);
            app.normalizeSkill(invalid[i]);
        }
        vm.expectRevert(AgentSkill.InvalidSkill.selector);
        app.normalizeSkill(string(new bytes(49)));
        (, string memory name) = app.normalizeSkill("C++ / C# .NET UI/UX");
        assertEq(name, "c++ / c# .net ui/ux");
        (, name) = app.normalizeSkill("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuv");
        assertEq(bytes(name).length, 48);
    }

    function test_skillLimitHideReactivateAndCatalogDeduplication() public {
        vm.startPrank(alice);
        for (uint256 i = 1; i < 32; ++i) {
            app.registerSkill(1, string.concat("skill ", vm.toString(i)));
        }
        vm.expectRevert(AgentSkill.SkillLimitReached.selector);
        app.registerSkill(1, "too many");
        app.hideSkill(1, solidityId);
        assertEq(app.getAgentSkills(1).length, 31);
        vm.expectRevert(AgentSkill.SkillNotActive.selector);
        app.hideSkill(1, solidityId);
        app.registerSkill(1, "solidity");
        vm.stopPrank();
        assertEq(app.skillAgentCount(solidityId), 1);
        (, uint256 catalogCount) = app.getSkills(0, 50);
        assertEq(catalogCount, 32);
        (AgentSkill.Skill[] memory last,) = app.getSkills(30, 50);
        assertEq(last.length, 2);
        (last,) = app.getSkills(32, 1);
        assertEq(last.length, 0);
    }

    function test_endorsementCountsUniqueAgentsAndWallets() public {
        vm.prank(bob);
        app.endorseSkill(2, 1, solidityId);
        assertTrue(app.hasEndorsed(1, solidityId, 2));
        assertTrue(app.hasWalletEndorsed(1, solidityId, bob));
        assertEq(app.getAgentSkills(1)[0].endorsements, 1);
        vm.prank(bob);
        vm.expectRevert(AgentSkill.DuplicateEndorsement.selector);
        app.endorseSkill(2, 1, solidityId);
        identity.setOwner(4, bob);
        vm.prank(bob);
        vm.expectRevert(AgentSkill.DuplicateEndorsement.selector);
        app.endorseSkill(4, 1, solidityId);
        // Transfer does not allow the same identity to vote again through a fresh wallet.
        identity.setOwner(2, carol);
        vm.prank(carol);
        vm.expectRevert(AgentSkill.DuplicateEndorsement.selector);
        app.endorseSkill(2, 1, solidityId);
        vm.prank(carol);
        app.endorseSkill(3, 1, solidityId);
        assertEq(app.getAgentSkills(1)[0].endorsements, 2);
    }

    function test_endorsementRejectsSelfSameOwnerUnregisteredAndInactive() public {
        vm.prank(alice);
        vm.expectRevert(AgentSkill.SelfEndorsement.selector);
        app.endorseSkill(1, 1, solidityId);
        identity.setOwner(4, alice);
        vm.prank(alice);
        vm.expectRevert(AgentSkill.SelfEndorsement.selector);
        app.endorseSkill(4, 1, solidityId);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.NotAgentOwner.selector, 2));
        app.endorseSkill(2, 1, solidityId);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.UnregisteredAgent.selector, 999));
        app.endorseSkill(999, 1, solidityId);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.UnregisteredAgent.selector, 999));
        app.endorseSkill(2, 999, solidityId);
        vm.prank(bob);
        vm.expectRevert(AgentSkill.SkillNotActive.selector);
        app.endorseSkill(2, 1, keccak256("writing"));
        vm.prank(alice);
        app.hideSkill(1, solidityId);
        vm.prank(bob);
        vm.expectRevert(AgentSkill.SkillNotActive.selector);
        app.endorseSkill(2, 1, solidityId);
    }

    function test_hidingAndReactivationDoNotEraseOrReplayEndorsements() public {
        vm.prank(bob);
        app.endorseSkill(2, 1, solidityId);
        vm.startPrank(alice);
        app.hideSkill(1, solidityId);
        app.registerSkill(1, "solidity");
        vm.stopPrank();
        assertEq(app.getAgentSkills(1)[0].endorsements, 1);
        vm.prank(bob);
        vm.expectRevert(AgentSkill.DuplicateEndorsement.selector);
        app.endorseSkill(2, 1, solidityId);
    }

    function test_priorReputationAndHistoryContributeOnFirstRegistration() public {
        for (uint256 i; i < 20; ++i) {
            reputation.add(2, publisher, 90, 0, "starred", "");
        }
        vm.prank(bob);
        app.registerSkill(2, "Solidity");
        AgentSkill.ScoreBreakdown memory score = app.getScoreBreakdown(2, solidityId);
        assertEq(score.reputationPoints, 5400);
        assertEq(score.historyPoints, 2250);
        assertEq(score.endorsementPoints, 0);
        assertEq(score.total, 7650);
        assertEq(score.completedWork, 0);
        assertEq(score.historySource, 0);
        (AgentSkill.RankedAgent[] memory ranked,,) = app.getTopAgents(solidityId, 0, 50, 20);
        assertEq(ranked[0].agentId, 2);
        assertEq(ranked[1].score.total, 0);
    }

    function test_filtersPublishersAndUnitsAndReflectsRevocationsLive() public {
        reputation.add(1, publisher, 80, 0, "starred", "");
        reputation.add(1, carol, 100, 0, "starred", "");
        reputation.add(1, publisher, 500, 0, "responseTime", "");
        AgentSkill.ScoreBreakdown memory score = app.getScoreBreakdown(1, solidityId);
        assertEq(score.feedbackCount, 1);
        assertEq(score.reputationBps, 8000);
        reputation.revoke(1, 0);
        score = app.getScoreBreakdown(1, solidityId);
        assertEq(score.feedbackCount, 0);
        assertEq(score.total, 0);
    }

    function test_secondaryTagAndPolicyVersionAreUsed() public {
        reputation.add(1, publisher, 99, 0, "quality", "audit");
        reputation.add(1, publisher, 10, 0, "quality", "design");
        vm.prank(LAUNCH_OWNER);
        app.setReputationMetric("quality", "audit");
        AgentSkill.ScoreBreakdown memory score = app.getScoreBreakdown(1, solidityId);
        assertEq(score.reputationBps, 9900);
        assertEq(score.feedbackCount, 1);
        assertEq(score.policyVersion, 2);
    }

    function test_decimalNormalizationAndClamping() public {
        _mockSummary(20, 9977, 2);
        assertEq(app.getScoreBreakdown(1, solidityId).reputationBps, 9977);
        _mockSummary(20, 99_770_000_000_000_000_000, 18);
        assertEq(app.getScoreBreakdown(1, solidityId).reputationBps, 9977);
        _mockSummary(20, type(int128).max, 18);
        assertEq(app.getScoreBreakdown(1, solidityId).reputationBps, 10_000);
        _mockSummary(20, type(int128).min, 18);
        assertEq(app.getScoreBreakdown(1, solidityId).reputationBps, 0);
        _mockSummary(0, 100, 0);
        assertEq(app.getScoreBreakdown(1, solidityId).total, 0);
        _mockSummary(20, 100, 19);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, REPUTATION, 1));
        app.getScoreBreakdown(1, solidityId);
    }

    function test_mixedDecimalRegistrySummaryMatchesInterface() public {
        reputation.add(1, publisher, 90, 0, "starred", "");
        reputation.add(1, publisher, 9980, 2, "starred", "");
        // The official implementation returns the mode precision (lowest precision breaks this tie).
        assertEq(app.getScoreBreakdown(1, solidityId).reputationBps, 9400);
    }

    function test_acceptedWorkReplacesFallbackWithQualityAndDepth() public {
        _mockSummary(20, 90, 0);
        work.set(1, 20, 18);
        vm.prank(LAUNCH_OWNER);
        app.setWorkHistory(address(work));
        AgentSkill.ScoreBreakdown memory score = app.getScoreBreakdown(1, solidityId);
        assertEq(score.historySource, 1);
        assertEq(score.historyBps, 9000);
        assertEq(score.completedWork, 20);
        assertEq(score.acceptedWork, 18);
        work.set(1, 1, 1);
        assertEq(app.getScoreBreakdown(1, solidityId).historyBps, 500);
        work.set(1, 100, 60);
        assertEq(app.getScoreBreakdown(1, solidityId).historyBps, 6000);
        work.set(1, 0, 0);
        assertEq(app.getScoreBreakdown(1, solidityId).historyBps, 0);
        vm.prank(LAUNCH_OWNER);
        app.clearWorkHistory();
        assertEq(app.getScoreBreakdown(1, solidityId).historyBps, 9000);
        assertEq(app.getScoreBreakdown(1, solidityId).historySource, 0);
    }

    function test_sourceFailureIsExplicitAndDoesNotDisableSkillWrites() public {
        reputation.setFailure(true);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, REPUTATION, 1));
        app.getScoreBreakdown(1, solidityId);
        vm.prank(bob);
        app.endorseSkill(2, 1, solidityId);
        reputation.setFailure(false);
        vm.prank(LAUNCH_OWNER);
        app.setWorkHistory(address(work));
        work.setFailure(true);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, address(work), 1));
        app.getScoreBreakdown(1, solidityId);
        work.setFailure(false);
        work.set(1, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.ScoreSourceUnavailable.selector, address(work), 1));
        app.getScoreBreakdown(1, solidityId);
    }

    function test_missingOrMismatchedReputationRegistryFailsClearly() public {
        vm.mockCall(REPUTATION, abi.encodeWithSignature("getIdentityRegistry()"), abi.encode(address(work)));
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.RegistryUnavailable.selector, REPUTATION));
        app.getScoreBreakdown(1, solidityId);
        vm.clearMockedCalls();
        vm.etch(REPUTATION, "");
        vm.expectRevert(abi.encodeWithSelector(AgentSkill.RegistryUnavailable.selector, REPUTATION));
        app.getTopAgents(solidityId, 0, 20, 20);
    }

    function test_unconfiguredRankingsDoNotPretendReputationIsZero() public {
        AgentSkill unconfigured = new AgentSkill(LAUNCH_OWNER);
        vm.prank(alice);
        unconfigured.registerSkill(1, "Solidity");
        vm.expectRevert(AgentSkill.RankingNotConfigured.selector);
        unconfigured.getScoreBreakdown(1, solidityId);
        vm.expectRevert(AgentSkill.RankingNotConfigured.selector);
        unconfigured.getTopAgents(solidityId, 0, 20, 20);
        assertEq(unconfigured.getAgentSkills(1).length, 1);
    }

    function test_adminValidationAndTwoStepOwnership() public {
        address[] memory clients = new address[](0);
        vm.prank(LAUNCH_OWNER);
        vm.expectRevert(AgentSkill.InvalidPolicy.selector);
        app.setTrustedClients(clients);
        clients = new address[](2);
        clients[0] = publisher;
        clients[1] = publisher;
        vm.prank(LAUNCH_OWNER);
        vm.expectRevert(AgentSkill.InvalidPolicy.selector);
        app.setTrustedClients(clients);
        clients[1] = address(0);
        vm.prank(LAUNCH_OWNER);
        vm.expectRevert(AgentSkill.InvalidPolicy.selector);
        app.setTrustedClients(clients);
        clients = new address[](33);
        vm.prank(LAUNCH_OWNER);
        vm.expectRevert(AgentSkill.InvalidPolicy.selector);
        app.setTrustedClients(clients);
        vm.prank(LAUNCH_OWNER);
        vm.expectRevert(AgentSkill.InvalidPolicy.selector);
        app.setReputationMetric("", "");
        vm.prank(LAUNCH_OWNER);
        vm.expectRevert(AgentSkill.InvalidPolicy.selector);
        app.setWorkHistory(alice);
        work.setIdentity(alice);
        vm.prank(LAUNCH_OWNER);
        vm.expectRevert(AgentSkill.InvalidPolicy.selector);
        app.setWorkHistory(address(work));
        vm.prank(LAUNCH_OWNER);
        vm.expectRevert(AgentSkill.OwnershipRequired.selector);
        app.renounceOwnership();
        vm.prank(LAUNCH_OWNER);
        app.transferOwnership(bob);
        assertEq(app.owner(), LAUNCH_OWNER);
        assertEq(app.pendingOwner(), bob);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        app.acceptOwnership();
        vm.prank(bob);
        app.acceptOwnership();
        assertEq(app.owner(), bob);
        assertEq(app.pendingOwner(), address(0));
        vm.prank(LAUNCH_OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, LAUNCH_OWNER));
        app.clearWorkHistory();
    }

    function test_everyPolicySetterRejectsNonOwner() public {
        address[] memory clients = new address[](1);
        clients[0] = publisher;
        vm.startPrank(alice);
        bytes memory errorData = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.expectRevert(errorData);
        app.setTrustedClients(clients);
        vm.expectRevert(errorData);
        app.setReputationMetric("quality", "");
        vm.expectRevert(errorData);
        app.setWorkHistory(address(work));
        vm.expectRevert(errorData);
        app.clearWorkHistory();
        vm.expectRevert(errorData);
        app.transferOwnership(alice);
        vm.stopPrank();
    }

    function test_paginationSortsTiesAndSkipsHiddenCandidates() public {
        // Deliberately register out of numeric order.
        vm.prank(carol);
        app.registerSkill(3, "solidity");
        vm.prank(bob);
        app.registerSkill(2, "solidity");
        _mockSummary(20, 80, 0);
        (AgentSkill.RankedAgent[] memory ranked, uint256 next, uint256 total) =
            app.getTopAgents(solidityId, 0, 2, 2);
        assertEq(ranked[0].agentId, 1);
        assertEq(ranked[1].agentId, 3);
        assertEq(next, 2);
        assertEq(total, 3);
        (ranked, next,) = app.getTopAgents(solidityId, next, 2, 2);
        assertEq(ranked.length, 1);
        assertEq(ranked[0].agentId, 2);
        assertEq(next, 3);
        (ranked,,) = app.getTopAgents(solidityId, 0, 50, 2);
        assertEq(ranked[0].agentId, 1);
        assertEq(ranked[1].agentId, 2);
        vm.prank(alice);
        app.hideSkill(1, solidityId);
        (ranked,,) = app.getTopAgents(solidityId, 0, 50, 20);
        assertEq(ranked.length, 2);
        assertEq(ranked[0].agentId, 2);
        (ranked,,) = app.getTopAgents(solidityId, 3, 50, 20);
        assertEq(ranked.length, 0);
    }

    function test_invalidPagesAndEmptySkill() public {
        vm.expectRevert(AgentSkill.InvalidPage.selector);
        app.getTopAgents(solidityId, 0, 0, 1);
        vm.expectRevert(AgentSkill.InvalidPage.selector);
        app.getTopAgents(solidityId, 0, 51, 20);
        vm.expectRevert(AgentSkill.InvalidPage.selector);
        app.getTopAgents(solidityId, 0, 20, 21);
        vm.expectRevert(AgentSkill.InvalidPage.selector);
        app.getTopAgents(solidityId, 2, 20, 20);
        vm.expectRevert(AgentSkill.InvalidPage.selector);
        app.getSkills(0, 0);
        vm.expectRevert(AgentSkill.InvalidPage.selector);
        app.getSkills(type(uint256).max, 50);
        (AgentSkill.RankedAgent[] memory ranked, uint256 next, uint256 total) =
            app.getTopAgents(keccak256("unknown"), 0, 20, 20);
        assertEq(ranked.length, 0);
        assertEq(next, 0);
        assertEq(total, 0);
    }

    function test_noEtherEntrypoint() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool sent,) = address(app).call{value: 1}("");
        assertFalse(sent);
    }

    function testFuzz_scoreBoundedAndExact(int128 value, uint8 decimalSeed, uint64 count, uint8 votes)
        public
    {
        uint8 decimals = uint8(bound(decimalSeed, 0, 18));
        uint256 endorsements = bound(votes, 0, 30);
        _mockSummary(count, value, decimals);
        for (uint256 i; i < endorsements; ++i) {
            address voter = address(uint160(1000 + i));
            identity.setOwner(100 + i, voter);
            vm.prank(voter);
            app.endorseSkill(100 + i, 1, solidityId);
        }
        AgentSkill.ScoreBreakdown memory score = app.getScoreBreakdown(1, solidityId);
        uint256 expectedRating;
        if (count != 0 && value > 0) {
            expectedRating = uint256(uint128(value)) * 100 / 10 ** uint256(decimals);
            if (expectedRating > 10_000) expectedRating = 10_000;
        }
        uint256 depth = count < 20 ? count : 20;
        uint256 cappedVotes = endorsements < 20 ? endorsements : 20;
        uint256 expected = expectedRating * 6000 / 10_000 + (expectedRating * depth / 20) * 2500 / 10_000
            + cappedVotes * 1500 / 20;
        assertEq(score.total, expected);
        assertLe(score.total, 10_000);
        assertEq(score.endorsements, endorsements);
        assertEq(score.total, score.reputationPoints + score.historyPoints + score.endorsementPoints);
    }

    function testFuzz_workFormulaNoOverflow(uint64 completed, uint64 acceptedSeed) public {
        uint64 accepted = uint64(bound(acceptedSeed, 0, completed));
        work.set(1, completed, accepted);
        vm.prank(LAUNCH_OWNER);
        app.setWorkHistory(address(work));
        AgentSkill.ScoreBreakdown memory score = app.getScoreBreakdown(1, solidityId);
        assertLe(score.historyBps, 10_000);
        assertEq(score.completedWork, completed);
        assertEq(score.acceptedWork, accepted);
        if (completed > 0) {
            uint256 depth = completed < 20 ? completed : 20;
            assertEq(score.historyBps, uint256(accepted) * 10_000 * depth / (uint256(completed) * 20));
        }
    }

    function testFuzz_sortReturnsActualTopCandidates(uint16[8] memory ratings) public {
        for (uint256 i; i < 8; ++i) {
            identity.setOwner(10 + i, alice);
            vm.prank(alice);
            app.registerSkill(10 + i, "solidity");
            reputation.add(10 + i, publisher, int128(uint128(ratings[i] % 101)), 0, "starred", "");
        }
        (AgentSkill.RankedAgent[] memory ranked,,) = app.getTopAgents(solidityId, 0, 50, 5);
        assertEq(ranked.length, 5);
        for (uint256 i = 1; i < ranked.length; ++i) {
            assertGe(ranked[i - 1].score.total, ranked[i].score.total);
            if (ranked[i - 1].score.total == ranked[i].score.total) {
                assertLt(ranked[i - 1].agentId, ranked[i].agentId);
            }
        }
        for (uint256 i; i < 8; ++i) {
            uint256 score = app.getScoreBreakdown(10 + i, solidityId).total;
            bool included;
            for (uint256 j; j < ranked.length; ++j) {
                if (ranked[j].agentId == 10 + i) included = true;
            }
            if (!included) assertLe(score, ranked[ranked.length - 1].score.total);
        }
    }

    function testFuzz_normalizationIsIdempotent(bytes memory arbitrary) public view {
        try app.normalizeSkill(string(arbitrary)) returns (bytes32 id, string memory canonical) {
            (bytes32 idAgain, string memory again) = app.normalizeSkill(canonical);
            assertEq(idAgain, id);
            assertEq(again, canonical);
            assertGt(bytes(canonical).length, 0);
            assertLe(bytes(canonical).length, 48);
        } catch {}
    }

    function _mockSummary(uint64 count, int128 value, uint8 decimals) internal {
        vm.mockCall(
            REPUTATION,
            abi.encodeWithSelector(MockReputationRegistry.getSummary.selector),
            abi.encode(count, value, decimals)
        );
    }
}
