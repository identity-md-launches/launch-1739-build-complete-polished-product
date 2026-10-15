import { useState } from 'react';
import { useConnection } from 'wagmi';
import { getWalletClient } from 'wagmi/actions';
import { useQueryClient } from '@tanstack/react-query';
import { type Hash } from 'viem';
import { abi, chain, config, CONTRACT, publicClient, verifyDeployment, verifyOwner, type Snapshot } from './chain';
import { readableError } from './core';

export type Action = { kind: 'register'; agentId: bigint; name: string } | { kind: 'endorse'; agentId: bigint; endorserId: bigint; skillId: Hash } | { kind: 'hide'; agentId: bigint; skillId: Hash };
export type Tx = { phase: 'checking' | 'wallet' | 'pending' | 'success' | 'error'; message: string; hash?: Hash };
export function useTransactions(snapshot?: Snapshot) {
  const { address, chainId } = useConnection();
  const queryClient = useQueryClient();
  const [tx, setTx] = useState<Tx>();
  const busy = !!tx && ['checking', 'wallet', 'pending'].includes(tx.phase);
  async function run(action: Action) {
    if (busy) return false;
    let hash: Hash | undefined;
    try {
      if (!address) throw new Error('Connect your wallet to continue.');
      if (chainId !== chain.id) throw new Error('Switch your wallet to Ethereum to continue.');
      if (!snapshot) throw new Error('Refresh the Ethereum connection before continuing.');
      setTx({ phase: 'checking', message: 'Checking ownership and transaction…' });
      // Resolve the current connection per action, including immediately after a network switch.
      const wallet = await getWalletClient(config, { chainId: chain.id });
      await verifyDeployment();
      await verifyOwner(action.kind === 'endorse' ? action.endorserId : action.agentId, address, snapshot.identity);
      const base = { address: CONTRACT, abi, account: address, chain } as const;
      // The contract simulation also checks duplicate endorsements and same-owner identities.
      if (action.kind === 'register') await publicClient.simulateContract({ ...base, functionName: 'registerSkill', args: [action.agentId, action.name] });
      else if (action.kind === 'hide') await publicClient.simulateContract({ ...base, functionName: 'hideSkill', args: [action.agentId, action.skillId] });
      else await publicClient.simulateContract({ ...base, functionName: 'endorseSkill', args: [action.endorserId, action.agentId, action.skillId] });
      const [accounts, currentChain] = await Promise.all([wallet.getAddresses(), wallet.getChainId()]);
      if (currentChain !== chain.id || accounts[0]?.toLowerCase() !== address.toLowerCase()) throw new Error('Your wallet changed during the check. Review the connected account and try again.');
      setTx({ phase: 'wallet', message: 'Review and confirm in your wallet.' });
      if (action.kind === 'register') hash = await wallet.writeContract({ ...base, functionName: 'registerSkill', args: [action.agentId, action.name] });
      else if (action.kind === 'hide') hash = await wallet.writeContract({ ...base, functionName: 'hideSkill', args: [action.agentId, action.skillId] });
      else hash = await wallet.writeContract({ ...base, functionName: 'endorseSkill', args: [action.endorserId, action.agentId, action.skillId] });
      setTx({ phase: 'pending', message: 'Transaction sent. Waiting for Ethereum…', hash });
      let cancelled = false;
      const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 180_000, onReplaced: replacement => {
        cancelled = replacement.reason === 'cancelled';
        hash = replacement.transactionReceipt.transactionHash;
        setTx({ phase: 'pending', message: cancelled ? 'Checking wallet cancellation…' : 'Waiting for the replacement transaction…', hash });
      } });
      if (cancelled) throw new Error('The transaction was cancelled in your wallet. No skill change was confirmed.');
      if (receipt.status !== 'success') throw new Error('The transaction reverted on Ethereum. No skill change was saved.');
      setTx({ phase: 'success', message: action.kind === 'register' ? 'Skill added. Your agent can now receive endorsements.' : action.kind === 'endorse' ? 'Endorsement recorded. Thank you for sharing your experience.' : 'Skill hidden from your profile.', hash });
      await queryClient.invalidateQueries({ queryKey: ['snapshot'] });
      await queryClient.invalidateQueries({ queryKey: ['profile'] });
      await queryClient.invalidateQueries({ queryKey: ['ranking'] });
      return true;
    } catch (error) {
      setTx({ phase: 'error', message: hash && /timed out|timeout|could not be found/i.test(String(error)) ? 'Confirmation is taking longer than expected. Check the transaction on Etherscan before trying again.' : readableError(error), hash });
      return false;
    }
  }
  return { tx, busy, run, clear: () => setTx(undefined) };
}
