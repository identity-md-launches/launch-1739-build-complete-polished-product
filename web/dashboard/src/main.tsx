import React from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { WagmiProvider } from 'wagmi';
import { config } from './chain';
import { App } from './App';
import './styles.css';

const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, refetchOnWindowFocus: false, staleTime: 30_000 } } });
class Boundary extends React.Component<{ children: React.ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  render() { return this.state.failed ? <main className="fatal"><h1>AgentSkill Dashboard</h1><p>The dashboard could not load. Reload to try again.</p><button className="button primary" onClick={() => location.reload()}>Reload dashboard</button></main> : this.props.children; }
}
createRoot(document.getElementById('root')!).render(<Boundary><WagmiProvider config={config}><QueryClientProvider client={queryClient}><App/></QueryClientProvider></WagmiProvider></Boundary>);
