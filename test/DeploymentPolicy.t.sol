// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentSkill} from "../src/AgentSkill.sol";

contract DeploymentFactoryProbe {
    function create(address owner, bytes32 salt) external returns (AgentSkill) {
        return new AgentSkill{salt: salt}(owner);
    }
}

contract DeploymentPolicyTest is Test {
    function test_factoryDeploymentHasExplicitOwnerBoundedRuntimeAndNoEscapeOpcodes() public {
        address owner = 0x7F4b7860bA9957128c5Ce416e94784cA98b5C976;
        DeploymentFactoryProbe factory = new DeploymentFactoryProbe();
        AgentSkill app = factory.create(owner, keccak256("AgentSkill deployment rehearsal"));
        assertEq(app.owner(), owner);
        assertTrue(app.owner() != address(factory));
        bytes memory code = address(app).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        assertLe(type(AgentSkill).creationCode.length + 32, 49_152);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden escape opcode");
        }
    }
}
