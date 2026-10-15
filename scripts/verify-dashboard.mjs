import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { keccak256, toUtf8Bytes } from '../web/vendor/ethers.min.js';

// Run forge build first. No network, wallet, or change to source is involved.
const artifact = JSON.parse(readFileSync(new URL('../out/AgentSkill.sol/AgentSkill.json', import.meta.url)));
const deployment = JSON.parse(readFileSync(new URL('../web/dashboard/src/deployment.json', import.meta.url)));
const source = readFileSync(new URL('../web/dashboard/src/abi.ts', import.meta.url), 'utf8');
const abi = JSON.parse(source.slice(source.indexOf('export const abi = ') + 19, source.lastIndexOf(' as const;')));
const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
assert.deepEqual(abi, artifact.abi);
assert.equal(keccak256(toUtf8Bytes(JSON.stringify(canonical(abi)))), `0x${deployment.abiHash}`);
assert.equal(keccak256(artifact.deployedBytecode.object), deployment.runtimeCodeHash);
console.log('PASS: compiled ABI equals frontend ABI; canonical ABI hash and runtime code hash match the pinned deployment record.');
