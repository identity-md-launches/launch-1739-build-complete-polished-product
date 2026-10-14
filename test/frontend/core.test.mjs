import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { normalizeSkill, parseAgentId, formatScore, mergeRanked, loadLeaderboard, safeHttpUrl, readableError } from "../../web/core.js";
import { Interface } from "../../web/vendor/ethers.min.js";

const candidate = (agentId, total) => ({ agentId: BigInt(agentId), score: { total: BigInt(total) } });

test("skill normalization matches canonical Solidity labels and rejects unsupported input", () => {
  assert.equal(normalizeSkill("  Security   AUDIT "), "security audit");
  assert.equal(normalizeSkill("C++ / C# .NET UI/UX"), "c++ / c# .net ui/ux");
  for (const input of ["", " ", "---", "<script>", "a\nb", "é", "a".repeat(49)]) assert.throws(() => normalizeSkill(input));
  assert.equal(normalizeSkill("A".repeat(48)), "a".repeat(48));
});

test("agent IDs preserve full uint256 precision, including token zero", () => {
  assert.equal(parseAgentId("0"), 0n);
  assert.equal(parseAgentId(" 001 "), 1n);
  assert.equal(parseAgentId(String(2n ** 256n - 1n)), 2n ** 256n - 1n);
  for (const input of ["", "-1", "1.1", "1e10", "0xff", String(2n ** 256n)]) assert.throws(() => parseAgentId(input));
  assert.equal(formatScore(7650n), "76.50");
});

test("global ranking merges every page, breaks ties numerically, and deduplicates", () => {
  const results = mergeRanked([[candidate(50, 6000), candidate(10, 0)], [candidate(500, 9000), candidate(2, 6000)], [candidate(50, 6000)]], 3);
  assert.deepEqual(results.map(x => x.agentId), [500n, 2n, 50n]);
});

test("leaderboard reads all candidates at the same block and promotes later-page winners", async () => {
  const calls = [], progress = [];
  const contract = { async getTopAgents(skill, offset, scan, results, options) {
    calls.push({ skill, offset, scan, results, options });
    if (offset === 0n) return [[candidate(1, 100), candidate(2, 200)], 20n, 41n];
    if (offset === 20n) return [[candidate(40, 8000)], 40n, 41n];
    return [[candidate(41, 9999)], 41n, 41n];
  } };
  const result = await loadLeaderboard(contract, "skill-hash", 1000, { onProgress: (...args) => progress.push(args) });
  assert.equal(result.ranked[0].agentId, 41n);
  assert.equal(result.totalCandidates, 41n);
  assert.equal(calls.length, 3);
  assert.ok(calls.every(c => c.options.blockTag === 1000));
  assert.deepEqual(progress.at(-1), [41n, 41n]);
});

test("leaderboard handles empty sets, hidden candidates, cancellations, and broken cursors", async () => {
  const empty = { async getTopAgents() { return [[], 0n, 0n]; } };
  assert.deepEqual((await loadLeaderboard(empty, "", 1)).ranked, []);
  assert.equal(await loadLeaderboard(empty, "", 1, { cancelled: () => true }), null);
  const hidden = { async getTopAgents(_skill, offset) { return offset === 0n ? [[], 20n, 21n] : [[candidate(21, 80)], 21n, 21n]; } };
  assert.equal((await loadLeaderboard(hidden, "", 1)).ranked[0].agentId, 21n);
  const broken = { async getTopAgents() { return [[], 0n, 30n]; } };
  await assert.rejects(() => loadLeaderboard(broken, "", 1), /cursor/);
});

test("failed evidence reads reject the whole global ranking rather than return a biased partial list", async () => {
  const broken = { async getTopAgents(_skill, offset) {
    if (offset === 0n) return [[candidate(1, 100)], 20n, 21n];
    throw new Error("RPC interrupted");
  } };
  await assert.rejects(() => loadLeaderboard(broken, "", 1), /RPC interrupted/);
});

test("external document links reject executable, credentialed, and private destinations", () => {
  assert.equal(safeHttpUrl("https://example.com/agent.json"), "https://example.com/agent.json");
  for (const url of ["javascript:alert(1)", "data:text/html,x", "http://example.com", "https://localhost", "https://192.168.1.1", "https://[::1]", "https://user:pass@example.com", "https://agent.local"]) assert.equal(safeHttpUrl(url), null);
  assert.equal(safeHttpUrl("http://127.0.0.1:8545", { allowLocal: true }), "http://127.0.0.1:8545/");
});

test("real ABI custom errors decode into actionable messages and vendor supports browser interface", async () => {
  const abi = JSON.parse(await readFile(new URL("../../web/AgentSkill.abi.json", import.meta.url)));
  const iface = new Interface(abi);
  const error = iface.encodeErrorResult("DuplicateEndorsement");
  assert.match(readableError({ data: error }, iface), /already endorsed/);
  assert.match(readableError({ code: 4001 }), /cancelled/);
  assert.match(readableError({ code: "NETWORK_ERROR" }), /connection/);
  const call = iface.encodeFunctionData("registerSkill", [1n, "solidity"]);
  assert.equal(iface.parseTransaction({ data: call }).args[1], "solidity");
});

test("committed ABI matches the local compiled contract when artifacts are present", async t => {
  let artifact;
  try { artifact = JSON.parse(await readFile(new URL("../../out/AgentSkill.sol/AgentSkill.json", import.meta.url))); }
  catch { t.skip("Run forge build to compare the generated ABI."); return; }
  const delivered = JSON.parse(await readFile(new URL("../../web/AgentSkill.abi.json", import.meta.url)));
  assert.deepEqual(delivered, artifact.abi);
});
