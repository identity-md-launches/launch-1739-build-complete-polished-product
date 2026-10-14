// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AgentSkill} from "../src/AgentSkill.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockReputationRegistry} from "./mocks/MockReputationRegistry.sol";

/// @dev Stateful model exercises changing ownership, advertising, and votes in arbitrary order.
contract SkillHandler is Test {
    AgentSkill public app;
    MockIdentityRegistry public identity;
    bytes32 public skillId;
    uint256 public expectedEndorsements;
    bool public advertised = true;
    mapping(uint256 => bool) public identityVoted;
    mapping(address => bool) public walletVoted;

    constructor(AgentSkill app_, MockIdentityRegistry registry_) {
        app = app_;
        identity = registry_;
        skillId = keccak256("solidity");
    }

    function endorse(uint8 identitySeed) external {
        uint256 id = 2 + uint256(identitySeed) % 8;
        address owner = identity.ownerOf(id);
        vm.prank(owner);
        try app.endorseSkill(id, 1, skillId) {
            assertTrue(advertised);
            assertTrue(owner != identity.ownerOf(1));
            assertFalse(identityVoted[id]);
            assertFalse(walletVoted[owner]);
            identityVoted[id] = true;
            walletVoted[owner] = true;
            ++expectedEndorsements;
        } catch {
            assertTrue(!advertised || owner == identity.ownerOf(1) || identityVoted[id] || walletVoted[owner]);
        }
    }

    function transfer(uint8 identitySeed, uint8 walletSeed) external {
        uint256 id = 1 + uint256(identitySeed) % 9;
        identity.setOwner(id, address(uint160(100 + uint256(walletSeed) % 12)));
    }

    function toggle() external {
        vm.prank(identity.ownerOf(1));
        if (advertised) app.hideSkill(1, skillId);
        else app.registerSkill(1, " SOLIDITY ");
        advertised = !advertised;
    }
}

contract AgentSkillInvariantTest is StdInvariant, Test {
    AgentSkill internal app;
    SkillHandler internal handler;
    MockIdentityRegistry internal identity;

    function setUp() public {
        address registry = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
        address reputation = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
        vm.etch(registry, address(new MockIdentityRegistry()).code);
        vm.etch(reputation, address(new MockReputationRegistry()).code);
        identity = MockIdentityRegistry(registry);
        app = new AgentSkill(address(this));
        address[] memory clients = new address[](1);
        clients[0] = makeAddr("historical publisher");
        app.setTrustedClients(clients);
        for (uint256 i = 1; i <= 9; ++i) {
            identity.setOwner(i, address(uint160(100 + i)));
        }
        vm.prank(identity.ownerOf(1));
        app.registerSkill(1, "solidity");
        handler = new SkillHandler(app, identity);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = SkillHandler.endorse.selector;
        selectors[1] = SkillHandler.transfer.selector;
        selectors[2] = SkillHandler.toggle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_endorsementConservationAndNoDuplicateCatalogEntries() public view {
        assertEq(app.skillAgentCount(handler.skillId()), 1);
        (AgentSkill.Skill[] memory catalog, uint256 total) = app.getSkills(0, 50);
        assertEq(total, 1);
        assertEq(catalog[0].id, handler.skillId());
        AgentSkill.Skill[] memory skills = app.getAgentSkills(1);
        assertEq(skills.length, handler.advertised() ? 1 : 0);
        if (handler.advertised()) {
            assertEq(skills[0].endorsements, handler.expectedEndorsements());
            AgentSkill.ScoreBreakdown memory score = app.getScoreBreakdown(1, handler.skillId());
            assertEq(score.endorsements, handler.expectedEndorsements());
            assertLe(score.total, 10_000);
        }
        for (uint256 i = 2; i <= 9; ++i) {
            assertEq(app.hasEndorsed(1, handler.skillId(), i), handler.identityVoted(i));
        }
        for (uint256 i = 100; i < 112; ++i) {
            assertEq(
                app.hasWalletEndorsed(1, handler.skillId(), address(uint160(i))),
                handler.walletVoted(address(uint160(i)))
            );
        }
    }
}
