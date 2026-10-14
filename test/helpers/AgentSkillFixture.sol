// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentSkill} from "src/AgentSkill.sol";
import {IReputationRegistry} from "src/interfaces/IReputationRegistry.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockReputationRegistry} from "../mocks/MockReputationRegistry.sol";
import {MockWorkHistory} from "../mocks/MockWorkHistory.sol";

/// @dev Local fixtures only: no fork, production deployment, environment mutation, or network dependency.
abstract contract AgentSkillFixture is Test {
    address internal constant IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant REPUTATION = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
    bytes32 internal constant SOLIDITY = keccak256("solidity");
    bytes32 internal constant RESEARCH = keccak256("research");

    AgentSkill internal app;
    MockIdentityRegistry internal identity;
    MockReputationRegistry internal reputation;
    MockWorkHistory internal work;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal publisher;

    function setUp() public virtual {
        alice = makeAddr("fixture alice");
        bob = makeAddr("fixture bob");
        carol = makeAddr("fixture carol");
        publisher = makeAddr("fixture publisher");
        vm.etch(IDENTITY, address(new MockIdentityRegistry()).code);
        vm.etch(REPUTATION, address(new MockReputationRegistry()).code);
        identity = MockIdentityRegistry(IDENTITY);
        reputation = MockReputationRegistry(REPUTATION);
        work = new MockWorkHistory();
        app = new AgentSkill(address(this));
        app.setTrustedClients(_clients());
        identity.setOwner(1, alice);
        identity.setOwner(2, bob);
        identity.setOwner(3, carol);
    }

    function _clients() internal view returns (address[] memory clients) {
        clients = new address[](1);
        clients[0] = publisher;
    }

    function _register(uint256 id, string memory name) internal returns (bytes32) {
        address owner = identity.ownerOf(id);
        vm.prank(owner);
        return app.registerSkill(id, name);
    }

    function _endorse(uint256 voter, uint256 target, bytes32 skill) internal {
        address owner = identity.ownerOf(voter);
        vm.prank(owner);
        app.endorseSkill(voter, target, skill);
    }

    function _hide(uint256 id, bytes32 skill) internal {
        address owner = identity.ownerOf(id);
        vm.prank(owner);
        app.hideSkill(id, skill);
    }

    /// @dev Exact calldata matching tests that the application forwards the configured publisher and tags.
    function _summary(uint256 id, uint64 count, int128 value, uint8 decimals) internal {
        vm.mockCall(
            REPUTATION,
            abi.encodeCall(
                IReputationRegistry.getSummary,
                (id, app.getTrustedClients(), app.reputationTag1(), app.reputationTag2())
            ),
            abi.encode(count, value, decimals)
        );
    }

    function _assertSameScore(AgentSkill.ScoreBreakdown memory a, AgentSkill.ScoreBreakdown memory b)
        internal
        pure
    {
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "score breakdown changed");
    }
}
