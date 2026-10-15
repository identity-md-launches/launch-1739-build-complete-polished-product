export const PRESET_SKILLS = ['Solidity', 'Security Audit', 'Frontend', 'UI/UX', 'Research', 'Tokenomics', 'Writing'] as const;

export function normalizeSkill(value: string) {
  if (!value.length || value.length > 48 || !/^[a-zA-Z0-9 +#./-]+$/.test(value) || !/[a-zA-Z0-9]/.test(value)) {
    throw new Error('Use 1–48 characters: letters, numbers, spaces, or + # . / -.');
  }
  return value.toLowerCase().trim().replace(/ +/g, ' ');
}
export function parseAgentId(value: string) {
  if (!/^\d+$/.test(value.trim())) throw new Error('Enter the numeric agent ID from the Identity Registry.');
  const id = BigInt(value.trim());
  if (id >= 2n ** 256n) throw new Error('That agent ID is too large. Check it and try again.');
  return id;
}
export const titleSkill = (name: string) => PRESET_SKILLS.find(s => s.toLowerCase() === name) ?? name;
export const formatScore = (points: bigint) => (Number(points) / 100).toFixed(2);
export const shortAddress = (address: string) => `${address.slice(0, 6)}…${address.slice(-4)}`;
export type Skill = { id: `0x${string}`; name: string; endorsements: bigint };
export type Score = {
  total: bigint; reputationPoints: bigint; historyPoints: bigint; endorsementPoints: bigint;
  reputationBps: bigint; historyBps: bigint; endorsements: bigint; feedbackCount: bigint;
  reputationValue: bigint; reputationDecimals: number; completedWork: bigint; acceptedWork: bigint;
  historySource: number; policyVersion: bigint;
};
export type RankedAgent = { agentId: bigint; score: Score; unavailable: boolean; unavailableSource: `0x${string}` };
export function mergeRanked(pages: readonly (readonly RankedAgent[])[], limit = 20) {
  const unique = new Map<string, RankedAgent>();
  for (const page of pages) for (const row of page) if (!row.unavailable) unique.set(String(row.agentId), row);
  return [...unique.values()].sort((a, b) => a.score.total !== b.score.total ? (a.score.total > b.score.total ? -1 : 1) : a.agentId < b.agentId ? -1 : a.agentId > b.agentId ? 1 : 0).slice(0, limit);
}
export async function scanRanking(
  readPage: (offset: bigint) => Promise<readonly [readonly RankedAgent[], bigint, bigint]>,
  onProgress: (done: bigint, total: bigint) => void = () => {},
  cancelled: () => boolean = () => false,
) {
  let offset = 0n, total = 0n, ranked: RankedAgent[] = [];
  const unavailable = new Map<string, RankedAgent>();
  do {
    if (cancelled()) throw new DOMException('Search cancelled', 'AbortError');
    const [entries, next, candidates] = await readPage(offset);
    if (next < offset || next > candidates || (next === offset && offset < candidates)) throw new Error('The ranking cursor did not advance. Retry the search.');
    ranked = mergeRanked([ranked, entries]);
    for (const row of entries) if (row.unavailable) unavailable.set(String(row.agentId), row);
    offset = next; total = candidates;
    onProgress(offset, total);
  } while (offset < total);
  if (cancelled()) throw new DOMException('Search cancelled', 'AbortError');
  return { ranked, unavailable: [...unavailable.values()], totalCandidates: total };
}
const messages: Record<string, string> = {
  RankingNotConfigured: 'The contract owner has not configured ranking sources yet. Skills and endorsements are still available.',
  NotAgentOwner: 'This wallet does not own that agent. Enter an agent ID you currently own.',
  UnregisteredAgent: 'This agent ID is not registered on Ethereum. Check the ID and try again.',
  ERC721NonexistentToken: 'This agent ID is not registered on Ethereum. Check the ID and try again.',
  SelfEndorsement: 'Choose an agent owned by someone else. You cannot endorse your own agents.',
  DuplicateEndorsement: 'This agent or wallet has already endorsed that skill.',
  SkillAlreadyActive: 'That skill is already on this agent’s profile.',
  SkillNotActive: 'This skill is no longer active. Refresh the profile.',
  SkillLimitReached: 'This agent already has 32 skills. Hide one before adding another.',
  InvalidSkill: 'Use 1–48 characters: letters, numbers, spaces, or + # . / -.',
  ScoreSourceUnavailable: 'An evidence source is unavailable. The score has not been replaced with zero.',
  InsufficientCallGas: 'The RPC cannot process this evidence read. Retry with the other public RPC.',
  RegistryUnavailable: 'The identity or reputation registry could not be read. Please retry.',
};
export function readableError(error: unknown): string {
  if (!(error instanceof Error)) return 'The request could not finish. Please try again.';
  let current: unknown = error;
  for (let i = 0; i < 8 && current && typeof current === 'object'; i++) {
    const e = current as { code?: number; name?: string; data?: { errorName?: string }; cause?: unknown };
    if (e.code === 4001 || e.name === 'UserRejectedRequestError') return 'Request cancelled in your wallet. Nothing was sent.';
    if (e.data?.errorName && messages[e.data.errorName]) return messages[e.data.errorName];
    if (e.name === 'InsufficientFundsError') return 'Your wallet needs ETH for the Ethereum network fee.';
    current = e.cause;
  }
  if (/HTTP|fetch|timeout|network|request took|RPC|could not be found|failed to get/i.test(error.message)) return 'Ethereum could not be reached. Check your connection and retry.';
  if (/execution reverted/i.test(error.message)) return 'The contract rejected this request. Check the agent ID, ownership, and skill, then retry.';
  return error.message.length < 220 ? error.message : 'The request could not finish. Please retry.';
}
