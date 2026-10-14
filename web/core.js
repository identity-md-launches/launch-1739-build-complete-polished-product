export const PRESET_SKILLS = ["Solidity", "Security Audit", "Frontend", "UI/UX", "Research", "Tokenomics", "Writing"];

export function normalizeSkill(value) {
  if (typeof value !== "string" || value.length < 1 || value.length > 48 || !/^[a-zA-Z0-9 +#./-]+$/.test(value) || !/[a-zA-Z0-9]/.test(value)) {
    throw new Error("Use 1–48 characters: letters, numbers, spaces, or + # . / -.");
  }
  return value.toLowerCase().trim().replace(/ +/g, " ");
}

export function parseAgentId(value) {
  const text = String(value).trim();
  if (!/^\d+$/.test(text)) throw new Error("Enter the numeric agent ID from the Identity Registry.");
  const id = BigInt(text);
  if (id >= 2n ** 256n) throw new Error("This agent ID is too large.");
  return id;
}

export function formatScore(points) { return (Number(points) / 100).toFixed(2); }
export function shortAddress(value) { return `${value.slice(0, 6)}…${value.slice(-4)}`; }
export function titleSkill(value) { return PRESET_SKILLS.find(s => s.toLowerCase() === value) || value; }

export function rankCompare(a, b) {
  const left = BigInt(a.score.total), right = BigInt(b.score.total);
  if (left !== right) return left > right ? -1 : 1;
  return BigInt(a.agentId) < BigInt(b.agentId) ? -1 : BigInt(a.agentId) > BigInt(b.agentId) ? 1 : 0;
}

/** Merge the top K of every candidate page to obtain the exact global top K. Unscored entries never rank. */
export function mergeRanked(pages, limit = 20) {
  const unique = new Map();
  for (const page of pages) for (const agent of page) if (!agent.unavailable) unique.set(String(agent.agentId), agent);
  return [...unique.values()].sort(rankCompare).slice(0, limit);
}

/** Candidates the contract flagged as unscorable at this block, with the evidence source that failed. */
export function collectUnavailable(pages) {
  const unique = new Map();
  for (const page of pages) for (const agent of page) if (agent.unavailable) unique.set(String(agent.agentId), { agentId: BigInt(agent.agentId), source: agent.unavailableSource });
  return [...unique.values()].sort((a, b) => (a.agentId < b.agentId ? -1 : a.agentId > b.agentId ? 1 : 0));
}

/**
 * Pin every eth_call to one block, including the policy, avoiding mixed-block leaderboard claims.
 * A page may stop before its scan limit when the RPC's call gas runs out; the loop simply continues
 * from the returned cursor, so a long history never blocks the rest of the leaderboard.
 */
export async function loadLeaderboard(contract, skillId, blockTag, { onProgress = () => {}, cancelled = () => false } = {}) {
  let offset = 0n, total = 0n, ranked = [], unavailable = [];
  do {
    if (cancelled()) return null;
    const page = await contract.getTopAgents(skillId, offset, 20, 20, { blockTag });
    if (cancelled()) return null;
    const [entries, next, candidates] = page;
    if (BigInt(next) < offset || (BigInt(next) === offset && offset < BigInt(candidates))) {
      throw new Error("The ranking cursor did not advance. Please check the deployment.");
    }
    total = BigInt(candidates);
    offset = BigInt(next);
    ranked = mergeRanked([ranked, entries]);
    unavailable = collectUnavailable([unavailable.map(u => ({ agentId: u.agentId, unavailable: true, unavailableSource: u.source })), entries]);
    onProgress(offset, total);
  } while (offset < total);
  return { ranked, unavailable, totalCandidates: total, blockTag };
}

export function safeHttpUrl(value, { allowLocal = false } = {}) {
  try {
    const url = new URL(value);
    if (url.username || url.password) return null;
    const host = url.hostname.toLowerCase();
    const local = host === "localhost" || host === "127.0.0.1" || host === "[::1]";
    if (allowLocal && local && ["http:", "https:"].includes(url.protocol)) return url.href;
    if (url.protocol !== "https:" || local || host.endsWith(".local") || host.endsWith(".internal") || /^\d+\./.test(host) || host.includes(":")) return null;
    return url.href;
  } catch { return null; }
}

export function readableError(error, contractInterface) {
  let name = error?.revert?.name;
  const data = error?.data || error?.info?.error?.data?.data || error?.info?.error?.data;
  if (!name && typeof data === "string" && contractInterface) {
    try { name = contractInterface.parseError(data)?.name; } catch { /* Generic transport error below. */ }
  }
  const messages = {
    RankingNotConfigured: "Rankings are waiting for the owner to publish trusted feedback sources. Skills can still be registered.",
    NotAgentOwner: "This wallet does not own that agent ID. Choose an identity you currently own.",
    UnregisteredAgent: "That agent ID is not registered in Ethereum’s Identity Registry.",
    ERC721NonexistentToken: "That agent ID is not registered in Ethereum’s Identity Registry.",
    SelfEndorsement: "Choose an agent owned by someone else. Self-endorsements are not allowed.",
    DuplicateEndorsement: "This agent or wallet has already endorsed that skill.",
    SkillAlreadyActive: "That skill is already on this agent’s profile.",
    SkillNotActive: "This agent no longer advertises that skill. Refresh to see the latest profile.",
    SkillLimitReached: "This agent already shows 32 skills. Hide one to make room for another.",
    InvalidSkill: "Use 1–48 characters: letters, numbers, spaces, or + # . / -.",
    ScoreSourceUnavailable: "An on-chain evidence source failed or needed more than its gas budget for this agent. No score has been substituted.",
    InsufficientCallGas: "This RPC does not allow enough gas for one evidence read. Choose another RPC, or the owner can lower the source gas budget.",
    RegistryUnavailable: "An official registry could not be read on this network. Check your Ethereum connection.",
    OwnableUnauthorizedAccount: "Only the deployment owner can change ranking policy.",
    InvalidPolicy: "Check the publisher list, metric tags, gas budget, or work adapter. The contract rejected this policy.",
  };
  if (messages[name]) return messages[name];
  if (error?.code === 4001 || error?.code === "ACTION_REJECTED" || error?.info?.error?.code === 4001) return "Request cancelled in your wallet. Nothing changed.";
  if (error?.code === "INSUFFICIENT_FUNDS") return "Your wallet needs ETH for the network transaction fee.";
  if (error?.code === "NETWORK_ERROR" || error?.code === "SERVER_ERROR" || error?.code === "TIMEOUT") return "The Ethereum connection is unavailable. Retry or choose another RPC in Connection.";
  return error?.shortMessage || error?.message || "Something interrupted the request. Please try again.";
}
