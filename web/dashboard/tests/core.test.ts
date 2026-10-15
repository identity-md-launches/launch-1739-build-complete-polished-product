import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeSkill, parseAgentId, mergeRanked, scanRanking, readableError, type RankedAgent, type Score } from '../src/core';
import { OPEN_IN } from '../src/open-in';
import { keccak256, stringToHex } from 'viem';
import { abi } from '../src/abi';
import deployment from '../src/deployment.json';

const score = (total: bigint) => ({ total } as Score);
const row = (id: bigint, points: bigint, unavailable = false) => ({ agentId: id, score: score(points), unavailable, unavailableSource: deployment.contractAddress as `0x${string}` });
test('skill normalization matches the contract’s ASCII and raw-length rules', () => {
  assert.equal(normalizeSkill('  Security   AUDIT  '), 'security audit');
  for (const skill of ['C++', 'C#', 'UI/UX', 'web3.js', 'front-end']) assert.equal(normalizeSkill(skill), skill.toLowerCase());
  for (const invalid of ['', ' ', '---', 'é', 'solidity\t', 'a'.repeat(49), '<script>']) assert.throws(() => normalizeSkill(invalid));
});
test('agent IDs preserve uint256 precision, including ID zero', () => {
  assert.equal(parseAgentId(' 00042 '), 42n);
  assert.equal(parseAgentId('0'), 0n);
  assert.equal(parseAgentId(String(2n ** 256n - 1n)), 2n ** 256n - 1n);
  for (const invalid of ['-1', '1.1', '1e3', '', '0x12', String(2n ** 256n)]) assert.throws(() => parseAgentId(invalid));
});
test('global ranking merges every page, ties by ID, and never ranks unavailable evidence', () => {
  const pages = [[row(4n, 9000n), row(2n, 5000n), row(1n, 9999n, true)], [row(8n, 9800n), row(3n, 9000n), row(4n, 9000n)]];
  assert.deepEqual(mergeRanked(pages).map(r => r.agentId), [8n, 3n, 4n, 2n]);
});
test('ranking honors returned cursors when an RPC page scans fewer candidates', async () => {
  const cursors: bigint[] = [];
  const pages: Record<string, readonly [RankedAgent[], bigint, bigint]> = {
    0: [[row(1n, 100n)], 1n, 42n], 1: [[row(22n, 700n), row(5n, 0n, true)], 21n, 42n], 21: [[row(42n, 9500n)], 42n, 42n],
  };
  const result = await scanRanking(async offset => { cursors.push(offset); return pages[String(offset)]; });
  assert.deepEqual(cursors, [0n, 1n, 21n]);
  assert.equal(result.ranked[0].agentId, 42n);
  assert.equal(result.unavailable[0].agentId, 5n);
  assert.equal(result.totalCandidates, 42n);
});
test('ranking rejects stalled and invalid cursors and can cancel obsolete requests', async () => {
  await assert.rejects(scanRanking(async () => [[], 0n, 2n]), /cursor/);
  await assert.rejects(scanRanking(async () => [[], 3n, 2n]), /cursor/);
  await assert.rejects(scanRanking(async () => [[], 0n, 0n], undefined, () => true), { name: 'AbortError' });
});
test('a failed later page never produces a misleading partial leaderboard', async () => {
  await assert.rejects(scanRanking(async offset => { if (offset) throw new Error('RPC failure'); return [[row(1n, 100n)], 20n, 40n]; }), /RPC failure/);
});
test('nested wallet rejection and contract errors have useful recovery messages', () => {
  assert.match(readableError(Object.assign(new Error('outer'), { cause: { code: 4001 } })), /cancelled/);
  assert.match(readableError(Object.assign(new Error('outer'), { cause: { data: { errorName: 'DuplicateEndorsement' } } })), /already endorsed/);
});
test('mobile wallet links preserve gateway subpaths, query strings, and profile hashes', () => {
  const url = 'https://gateway.example/ipfs/site/?mode=read#/agent/42';
  for (const wallet of OPEN_IN) {
    const link = wallet.href(url);
    assert.ok(link.startsWith('https://'));
    assert.ok(decodeURIComponent(link).includes(wallet.id === 'metamask' ? url.replace(/^https?:\/\//, '') : url));
  }
  assert.match(OPEN_IN.find(x => x.id === 'rabby')!.href(url), /_cmd=open-dapp&dapp=/);
});
test('committed ABI has the pinned deployment’s canonical keccak hash', () => {
  const canonical = (v: unknown): unknown => Array.isArray(v) ? v.map(canonical) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map(k => [k, canonical((v as Record<string, unknown>)[k])])) : v;
  assert.equal(keccak256(stringToHex(JSON.stringify(canonical(abi)))), `0x${deployment.abiHash}`);
});
