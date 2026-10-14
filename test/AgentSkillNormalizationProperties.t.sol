// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AgentSkillFixture} from "./helpers/AgentSkillFixture.sol";
import {AgentSkill} from "src/AgentSkill.sol";

contract AgentSkillNormalizationPropertiesTest is AgentSkillFixture {
    /// @dev Generate valid labels directly so every fuzz run reaches registration and canonicalization.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_caseAndSpacingVariantsShareIdentity(bytes32 entropy, uint8 leftSeed, uint8 rightSeed)
        public
    {
        uint256 leftLength = bound(leftSeed, 1, 14);
        uint256 rightLength = bound(rightSeed, 1, 14);
        bytes memory left = new bytes(leftLength);
        bytes memory right = new bytes(rightLength);
        for (uint256 i; i < leftLength; ++i) {
            left[i] = bytes1(uint8(97 + uint8(entropy[i]) % 26));
        }
        for (uint256 i; i < rightLength; ++i) {
            right[i] = bytes1(uint8(97 + uint8(entropy[16 + i]) % 26));
        }
        string memory canonical = string.concat(string(left), " ", string(right));
        bytes32 expectedId = keccak256(bytes(canonical));
        for (uint256 i; i < leftLength; ++i) {
            if (uint8(entropy[i]) % 2 == 0) left[i] = bytes1(uint8(left[i]) - 32);
        }
        for (uint256 i; i < rightLength; ++i) {
            if (uint8(entropy[16 + i]) % 2 == 0) right[i] = bytes1(uint8(right[i]) - 32);
        }
        string memory decorated = string.concat("  ", string(left), "   ", string(right), "  ");
        (bytes32 id, string memory normalized) = app.normalizeSkill(decorated);
        assertEq(id, expectedId);
        assertEq(normalized, canonical);
        (bytes32 repeated, string memory normalizedAgain) = app.normalizeSkill(normalized);
        assertEq(repeated, expectedId);
        assertEq(normalizedAgain, canonical);
        assertEq(_register(1, decorated), expectedId);
        vm.prank(alice);
        vm.expectRevert(AgentSkill.SkillAlreadyActive.selector);
        app.registerSkill(1, canonical);
        _hide(1, expectedId);
        _register(1, canonical);
        assertEq(app.skillAgentCount(expectedId), 1);
        assertEq(app.getAgentSkills(1)[0].name, canonical);
        (, uint256 total) = app.getSkills(0, 50);
        assertEq(total, 1);
    }

    function test_everyByteIsEitherDocumentedAsciiOrRejected() public {
        bytes memory allowed = bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 +#./-");
        for (uint256 c; c < 256; ++c) {
            bool permitted;
            for (uint256 j; j < allowed.length; ++j) {
                if (uint8(allowed[j]) == c) permitted = true;
            }
            bytes memory label = abi.encodePacked("a", bytes1(uint8(c)), "b");
            if (!permitted) {
                vm.expectRevert(AgentSkill.InvalidSkill.selector);
                app.normalizeSkill(string(label));
            } else {
                if (c >= 65 && c <= 90) label[1] = bytes1(uint8(c + 32));
                (bytes32 id, string memory canonical) =
                    app.normalizeSkill(string(abi.encodePacked("a", bytes1(uint8(c)), "b")));
                assertEq(canonical, string(label));
                assertEq(id, keccak256(label));
            }
        }
    }

    function test_inputLengthLimitAppliesBeforeWhitespaceTrimming() public {
        bytes memory raw = new bytes(48);
        raw[0] = "a";
        for (uint256 i = 1; i < raw.length; ++i) {
            raw[i] = " ";
        }
        (, string memory canonical) = app.normalizeSkill(string(raw));
        assertEq(canonical, "a");
        vm.expectRevert(AgentSkill.InvalidSkill.selector);
        app.normalizeSkill(string.concat(string(raw), " "));
    }

    function test_digitsOnlyAndPunctuationWithAlphanumericAreValid() public {
        (, string memory canonical) = app.normalizeSkill("  8004  ");
        assertEq(canonical, "8004");
        (, canonical) = app.normalizeSkill("+#./-0-/.#+");
        assertEq(canonical, "+#./-0-/.#+");
        vm.expectRevert(AgentSkill.InvalidSkill.selector);
        app.normalizeSkill(" + # . / - ");
    }
}
