import { createConfig, http } from 'wagmi';
import { injected, coinbaseWallet } from 'wagmi/connectors';
import { createPublicClient, defineChain, fallback, getAddress, keccak256, stringToHex, encodeFunctionData, decodeFunctionResult, type Address } from 'viem';
import { abi } from './abi';
import deployment from './deployment.json';
import { normalizeSkill, scanRanking, type Score, type Skill } from './core';

export { abi, deployment };
export const CONTRACT = getAddress(deployment.contractAddress);
export const chain = defineChain({
  id: deployment.chainId, name: 'Ethereum',
  nativeCurrency: deployment.walletAddChain.nativeCurrency,
  rpcUrls: { default: { http: deployment.rpcUrls } },
  blockExplorers: { default: { name: 'Etherscan', url: deployment.explorer } },
});
const transport = () => fallback(deployment.rpcUrls.map(url => http(url, { timeout: 8_000, retryCount: 0 })), { retryCount: 0, rank: false });
export const publicClient = createPublicClient({ chain, transport: transport(), batch: { multicall: false } });
export const config = createConfig({
  chains: [chain], multiInjectedProviderDiscovery: true,
  connectors: [injected(), coinbaseWallet({ appName: 'AgentSkill Dashboard', appLogoUrl: new URL('./favicon.svg', location.href).href, preference: { options: 'all' } })],
  transports: { [chain.id]: transport() },
});
export const identityAbi = [
  { type: 'function', name: 'ownerOf', stateMutability: 'view', inputs: [{ name: 'agentId', type: 'uint256' }], outputs: [{ name: 'owner', type: 'address' }] },
  { type: 'function', name: 'tokenURI', stateMutability: 'view', inputs: [{ name: 'agentId', type: 'uint256' }], outputs: [{ name: 'uri', type: 'string' }] },
] as const;
export async function verifyDeployment() {
  const [chainId, code] = await Promise.all([publicClient.getChainId(), publicClient.getBytecode({ address: CONTRACT })]);
  if (chainId !== deployment.chainId) throw new Error('The RPC returned a different network. Transactions are disabled.');
  if (!code || keccak256(code) !== deployment.runtimeCodeHash) throw new Error('The deployed contract could not be verified. Transactions are disabled.');
}
export async function loadSnapshot() {
  await verifyDeployment();
  const blockNumber = await publicClient.getBlockNumber({ cacheTime: 0 });
  const base = { address: CONTRACT, abi, blockNumber } as const;
  const [clients, version, tag1, tag2, workHistory, identity, owner, catalog] = await Promise.all([
    publicClient.readContract({ ...base, functionName: 'getTrustedClients' }),
    publicClient.readContract({ ...base, functionName: 'policyVersion' }),
    publicClient.readContract({ ...base, functionName: 'reputationTag1' }),
    publicClient.readContract({ ...base, functionName: 'reputationTag2' }),
    publicClient.readContract({ ...base, functionName: 'workHistory' }),
    publicClient.readContract({ ...base, functionName: 'IDENTITY_REGISTRY' }),
    publicClient.readContract({ ...base, functionName: 'owner' }),
    publicClient.readContract({ ...base, functionName: 'getSkills', args: [0n, 50n] }),
  ]);
  return { blockNumber, clients, version, tag1, tag2, workHistory, identity, owner, skills: [...catalog[0]], totalSkills: catalog[1], checkedAt: Date.now() };
}
export type Snapshot = Awaited<ReturnType<typeof loadSnapshot>>;
export async function loadRanking(name: string, snapshot: Snapshot, onProgress: (done: bigint, total: bigint) => void, signal: AbortSignal) {
  const skillId = keccak256(stringToHex(normalizeSkill(name)));
  const base = { address: CONTRACT, abi, blockNumber: snapshot.blockNumber } as const;
  const candidates = await publicClient.readContract({ ...base, functionName: 'skillAgentCount', args: [skillId] });
  if (candidates === 0n) return { ranked: [], unavailable: [], totalCandidates: 0n, configured: snapshot.clients.length > 0 };
  if (!snapshot.clients.length) return { ranked: [], unavailable: [], totalCandidates: candidates, configured: false };
  const data = await scanRanking(
    async offset => {
      const { data } = await publicClient.call({ to: CONTRACT, data: encodeFunctionData({ abi, functionName: 'getTopAgents', args: [skillId, offset, 20n, 20n] }), blockNumber: snapshot.blockNumber, gas: 30_000_000n });
      return decodeFunctionResult({ abi, functionName: 'getTopAgents', data: data! });
    },
    onProgress, () => signal.aborted,
  );
  return { ...data, configured: true };
}
export async function loadProfile(id: bigint, snapshot: Snapshot) {
  const [owner, skills] = await Promise.all([
    publicClient.readContract({ address: snapshot.identity, abi: identityAbi, functionName: 'ownerOf', args: [id], blockNumber: snapshot.blockNumber }),
    publicClient.readContract({ address: CONTRACT, abi, functionName: 'getAgentSkills', args: [id], blockNumber: snapshot.blockNumber }),
  ]);
  const rows: { skill: Skill; score?: Score; error?: unknown }[] = [];
  // Bounded concurrency avoids sending 32 expensive reads to a public RPC at once.
  for (let i = 0; i < skills.length; i += 3) {
    const batch = await Promise.all(skills.slice(i, i + 3).map(async skill => {
      if (!snapshot.clients.length) return { skill };
      try {
        const { data } = await publicClient.call({ to: CONTRACT, data: encodeFunctionData({ abi, functionName: 'getScoreBreakdown', args: [id, skill.id] }), blockNumber: snapshot.blockNumber, gas: 30_000_000n });
        const score = decodeFunctionResult({ abi, functionName: 'getScoreBreakdown', data: data! });
        return { skill, score };
      } catch (error) { return { skill, error }; }
    }));
    rows.push(...batch);
  }
  return { id, owner, rows, blockNumber: snapshot.blockNumber };
}
export async function verifyOwner(agentId: bigint, account: Address, identity: Address) {
  const owner = await publicClient.readContract({ address: identity, abi: identityAbi, functionName: 'ownerOf', args: [agentId] });
  if (owner.toLowerCase() !== account.toLowerCase()) throw new Error('This wallet does not own that agent. Enter an agent ID you currently own.');
}
