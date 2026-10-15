import { useState } from 'react';
import { useConnect, useConnectors, useConnection, useDisconnect, useSwitchChain } from 'wagmi';
import { getAddress } from 'viem';
import { chain } from './chain';
import { shortAddress, readableError } from './core';
import { Modal, Notice } from './components';
import { Icon } from './icons';
import { OPEN_IN, isMobileBrowser } from './open-in';

export function Wallet({ open, setOpen }: { open: boolean; setOpen: (value: boolean) => void }) {
  const { address, isConnected, chainId } = useConnection();
  const connectors = useConnectors();
  const { mutateAsync: connect, isPending, variables } = useConnect();
  const { mutate: disconnect } = useDisconnect();
  const { mutateAsync: switchChain, isPending: switching } = useSwitchChain();
  const [error, setError] = useState('');
  const mobile = isMobileBrowser();
  const named = connectors.some(c => c.type === 'injected' && c.id !== 'injected');
  const listed = [...connectors.filter(c => c.type === 'injected'), ...connectors.filter(c => c.type !== 'injected')]
    .filter(c => !(c.id === 'injected' && named) && !(mobile && c.type === 'injected'));
  const wrongChain = isConnected && chainId !== chain.id;
  const label = wrongChain ? 'Switch to Ethereum' : address ? shortAddress(getAddress(address)) : 'Connect';
  async function changeChain() {
    setError('');
    try { await switchChain({ chainId: chain.id }); setOpen(false); } catch (e) { setError(readableError(e)); setOpen(true); }
  }
  return <>
    <button className="button wallet-control" onClick={() => wrongChain ? void changeChain() : (setError(''), setOpen(true))} disabled={switching}><Icon name="wallet" size={18}/>{switching ? 'Switching…' : label}</button>
    {open && <Modal title={isConnected ? 'Connected wallet' : 'Connect a wallet'} onClose={() => setOpen(false)}>
      {isConnected && address ? <>
        <p className="muted">Your wallet controls your agent’s skills.</p>
        <p className="address wallet-address">{getAddress(address)}</p>
        <p className="network-label"><span className={`status-dot ${wrongChain ? 'warning' : ''}`}/>{wrongChain ? 'Switch to Ethereum to make changes.' : 'Ethereum mainnet'}</p>
        {wrongChain && <button className="button primary full-width" onClick={() => void changeChain()} disabled={switching}>Switch to Ethereum</button>}
        <button className="button full-width" onClick={() => { disconnect({}); setOpen(false); }}>Disconnect</button>
      </> : <>
        <p className="muted">Connect to add skills or endorse an agent. Browsing is always open.</p>
        <div className="wallet-list">
          {mobile && OPEN_IN.map(wallet => <a className="wallet-row" key={wallet.id} href={wallet.href(location.href)}><img src={`./wallets/${wallet.id}.svg`} width="28" height="28" alt=""/><span>Open in {wallet.name}</span><Icon name="external" size={16}/></a>)}
          {listed.map(connector => <button className="wallet-row" key={connector.uid} disabled={isPending} onClick={async () => {
            setError('');
            try { await connect({ connector }); setOpen(false); } catch (e) { setError(connector.id === 'injected' && !('ethereum' in window) ? 'No browser wallet was found. Install a wallet extension or choose Coinbase Wallet.' : readableError(e)); }
          }}>
            {connector.icon ? <img src={connector.icon} width="28" height="28" alt=""/> : connector.id === 'coinbaseWalletSDK' ? <img src="./wallets/coinbase.svg" width="28" height="28" alt=""/> : <Icon name="wallet" size={28}/>}
            <span>{connector.id === 'injected' ? 'Browser wallet' : connector.id === 'coinbaseWalletSDK' && mobile ? 'Coinbase Smart Wallet' : connector.name}{isPending && variables?.connector === connector ? ' · opening…' : ''}</span><Icon name="arrow" size={16}/>
          </button>)}
        </div>
        <p className="caption">Connecting does not send a transaction.</p>
      </>}
      {error && <Notice error>{error}</Notice>}
    </Modal>}
  </>;
}
