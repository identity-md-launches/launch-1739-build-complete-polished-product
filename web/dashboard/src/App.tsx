import { createContext, useContext, useEffect, useRef, useState, type FormEvent } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useConnection } from 'wagmi';
import { getAddress, type Hash } from 'viem';
import { CONTRACT, deployment, loadProfile, loadRanking, loadSnapshot, publicClient, abi, type Snapshot } from './chain';
import { PRESET_SKILLS, titleSkill, normalizeSkill, parseAgentId, formatScore, readableError, type Score, type Skill } from './core';
import { Icon, EmptyArt, type IconName } from './icons';
import { External, Loading, Modal, Notice } from './components';
import { Wallet } from './Wallet';
import { useTransactions, type Action, type Tx } from './transactions';

const Context = createContext<{
  snapshot?: Snapshot; loading: boolean; error: unknown; refresh: () => void;
  connect: () => void; busy: boolean; tx?: Tx; run: (action: Action) => Promise<boolean>;
}>({ loading: true, error: null, refresh: () => {}, connect: () => {}, busy: false, run: async () => false });
const useApp = () => useContext(Context);
function useRoute() {
  const [route, setRoute] = useState(location.hash.slice(1) || '/discover');
  useEffect(() => { const change = () => { setRoute(location.hash.slice(1) || '/discover'); window.scrollTo(0, 0); requestAnimationFrame(() => document.getElementById('main')?.focus({ preventScroll: true })); }; addEventListener('hashchange', change); return () => removeEventListener('hashchange', change); }, []);
  return route;
}
const skillHref = (skill: string) => `#/discover?skill=${encodeURIComponent(skill)}`;
const explorer = (address: string) => `${deployment.explorer}/address/${address}`;
const fmt = (value: bigint) => value.toLocaleString('en-US');

export function App() {
  const route = useRoute();
  const snapshot = useQuery({ queryKey: ['snapshot'], queryFn: loadSnapshot, staleTime: 60_000 });
  const [walletOpen, setWalletOpen] = useState(false);
  const transactions = useTransactions(snapshot.data);
  const page = route.startsWith('/agent') ? 'profile' : route.startsWith('/manage') ? 'manage' : route.startsWith('/about') ? 'about' : 'discover';
  const nav: { href: string; name: string; page: string; icon: IconName }[] = [
    { href: '#/discover', name: 'Discover', page: 'discover', icon: 'grid' },
    { href: '#/agent', name: 'Agent profile', page: 'profile', icon: 'user' },
    { href: '#/manage', name: 'My skills', page: 'manage', icon: 'skills' },
  ];
  return <Context.Provider value={{ snapshot: snapshot.data, loading: snapshot.isFetching, error: snapshot.error, refresh: () => void snapshot.refetch(), connect: () => setWalletOpen(true), busy: transactions.busy, tx: transactions.tx, run: transactions.run }}>
    <a className="skip-link" href="#main" onClick={e => { e.preventDefault(); document.getElementById('main')?.focus(); document.getElementById('main')?.scrollIntoView(); }}>Skip to content</a>
    <div className="app-shell">
      <aside className="sidebar">
        <a className="brand" href="#/discover" aria-label="AgentSkill Dashboard home"><img src="./favicon.svg" width="40" height="40" alt=""/><span>AgentSkill<span className="brand-subtitle">Dashboard</span></span></a>
        <nav className="main-nav" aria-label="Main navigation">{nav.map(item => <a key={item.page} href={item.href} className={page === item.page ? 'selected' : ''} aria-current={page === item.page ? 'page' : undefined}><Icon name={item.icon}/><span>{item.name}</span>{page === item.page && <span className="nav-dot"/>}</a>)}</nav>
        <div className="sidebar-bottom"><a className={`help-link ${page === 'about' ? 'selected' : ''}`} href="#/about"><Icon name="info"/>How it works</a><div className="sidebar-network"><span className="ethereum-mark" aria-hidden="true">◇</span><div>Ethereum<span className="caption">Mainnet</span></div><span className="status-dot"/></div></div>
      </aside>
      <div className="workspace">
        <header className="topbar"><span className="breadcrumb">Dashboard <span>/</span> <strong>{page === 'discover' ? 'Discover agents' : page === 'profile' ? 'Agent profile' : page === 'manage' ? 'My skills' : 'How it works'}</strong></span><a className="mobile-brand" href="#/discover"><img src="./favicon.svg" width="32" height="32" alt=""/><span>AgentSkill</span></a><div className="topbar-actions"><span className="chain-tag">Ethereum</span><Wallet open={walletOpen} setOpen={setWalletOpen}/></div></header>
        <nav className="mobile-nav" aria-label="Mobile navigation">{nav.map(item => <a key={item.page} href={item.href} aria-current={page === item.page ? 'page' : undefined} className={page === item.page ? 'selected' : ''}><Icon name={item.icon} size={18}/>{item.name}</a>)}</nav>
        <main id="main" tabIndex={-1}>
          {snapshot.error && snapshot.data && <Notice error>Refresh failed. Showing the previous snapshot at block {fmt(snapshot.data.blockNumber)}. <button className="text-button" onClick={() => void snapshot.refetch()}>Retry connection</button></Notice>}
          {page === 'discover' ? <Discover route={route}/> : page === 'profile' ? <ProfilePage route={route}/> : page === 'manage' ? <Manage/> : <About/>}
          {transactions.tx && <div className={`transaction-status ${transactions.tx.phase}`} role="status">
            <Icon name={transactions.tx.phase === 'success' ? 'check' : transactions.tx.phase === 'error' ? 'info' : 'refresh'}/><div><strong>{transactions.tx.message}</strong>{transactions.tx.hash && <External href={`${deployment.explorer}/tx/${transactions.tx.hash}`}>View transaction</External>}</div>{!transactions.busy && <button className="icon-button" aria-label="Dismiss transaction status" onClick={transactions.clear}><Icon name="close" size={18}/></button>}
          </div>}
        </main>
        <footer><span>Skills on-chain. Expertise in focus.</span><div><a href="#/about">How it works</a><External href={explorer(CONTRACT)}>View contract</External></div></footer>
      </div>
    </div>
  </Context.Provider>;
}

function Discover({ route }: { route: string }) {
  const { snapshot, loading, error, refresh } = useApp();
  const requested = new URLSearchParams(route.split('?')[1]).get('skill') || 'solidity';
  const [input, setInput] = useState(requested);
  const [fieldError, setFieldError] = useState('');
  const [progress, setProgress] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);
  let skill = ''; let routeError = '';
  try { skill = normalizeSkill(requested); } catch (e) { routeError = readableError(e); }
  useEffect(() => { setInput(titleSkill(skill || requested)); setFieldError(''); setProgress(''); }, [requested, skill]);
  const ranking = useQuery({
    queryKey: ['ranking', skill, String(snapshot?.blockNumber)],
    queryFn: ({ signal }) => loadRanking(skill, snapshot!, (done, total) => setProgress(`Checked ${fmt(done)} of ${fmt(total)} candidates`), signal),
    enabled: !!snapshot && !!skill,
  });
  function submit(e: FormEvent) {
    e.preventDefault();
    try { const name = normalizeSkill(input); setFieldError(''); if (name === skill) refresh(); else location.hash = skillHref(name).slice(1); }
    catch (e) { setFieldError(readableError(e)); inputRef.current?.focus(); }
  }
  return <>
    <div className="page-heading"><div><h1>Discover agents</h1><p>Find the right expertise, backed by on-chain evidence.</p></div><span className="quiet-label"><Icon name="shield" size={16}/>Built on Ethereum</span></div>
    <div className="discovery-grid">
      <div className="discovery-main">
        <section className="search-section" aria-label="Search agents by skill">
          <form onSubmit={submit} noValidate><label htmlFor="skill-search">What skill are you looking for?</label><div className="search-control"><Icon name="search"/><input ref={inputRef} id="skill-search" name="skill" value={input} onChange={e => setInput(e.target.value)} placeholder="Try Solidity or Research" maxLength={48} autoComplete="off" aria-invalid={!!fieldError || !!routeError} aria-describedby={fieldError || routeError ? 'search-error' : undefined}/><button className="button primary" type="submit">Search<Icon name="arrow" size={18}/></button></div>{(fieldError || routeError) && <p id="search-error" className="field-error" role="alert">{fieldError || routeError}</p>}</form>
          <div className="suggestions"><span>Try a skill</span>{['Solidity', 'Security Audit', 'Frontend', 'Research'].map(name => <a key={name} className={`chip ${skill === name.toLowerCase() ? 'active' : ''}`} href={skillHref(name.toLowerCase())} aria-current={skill === name.toLowerCase() ? 'true' : undefined}>{name}</a>)}</div>
        </section>
        <section className="results-section" aria-labelledby="results-heading" aria-busy={ranking.isFetching || loading}>
          <p className="sr-only" role="status">{ranking.isFetching ? `Searching for ${titleSkill(skill)} agents.` : ranking.data ? `${ranking.data.ranked.length} scored agents found for ${titleSkill(skill)}.` : error ? 'Ethereum connection unavailable.' : ''}</p>
          <div className="section-heading"><div><h2 id="results-heading">{skill ? `${titleSkill(skill)} agents` : 'Agent results'}</h2><p className="caption">Ranked by weighted score</p></div><button className="icon-button" aria-label="Refresh agent rankings" onClick={refresh} disabled={loading || ranking.isFetching}><Icon name="refresh" size={18}/></button></div>
          <div className="results-content">
            {(loading && !snapshot) || ranking.isFetching ? <Loading label={progress || 'Finding agents on Ethereum…'}/> : error && !snapshot ? <EmptyState icon="info" title="Can’t reach Ethereum" text="The public connection is unavailable. Your search is ready to retry." action={<button className="button" onClick={refresh}><Icon name="refresh" size={17}/>Retry connection</button>}/> : ranking.error ? <EmptyState icon="info" title="This search couldn’t finish" text={readableError(ranking.error)} action={<button className="button" onClick={() => void ranking.refetch()}>Retry search</button>}/> : ranking.data ? <>
              {ranking.data.ranked.length ? <><div className="ranking-labels" aria-hidden="true"><span>Agent</span><span>Endorsements</span><span>Score / 100</span></div><ol className="ranking-list">{ranking.data.ranked.map((row, i) => <li key={String(row.agentId)}><a href={`#/agent/${row.agentId}`} className="ranking-row"><span className="rank-number">{i + 1}</span><span className="agent-avatar"><Icon name="user" size={22}/></span><span className="agent-name">Agent #{String(row.agentId)}<span className="caption">{titleSkill(skill)}</span></span><span className="endorsement-count">{fmt(row.score.endorsements)}<span className="mobile-only caption"> endorsements</span></span><span className="score-value">{formatScore(row.score.total)}<Icon name="arrow" size={17}/></span></a></li>)}</ol><p className="result-footnote">Top {ranking.data.ranked.length} scored agents across all {fmt(ranking.data.totalCandidates)} historical candidates.</p></> : ranking.data.totalCandidates === 0n ? <EmptyState title="Room for your expertise" text={`No agents have registered “${titleSkill(skill)}” yet. Add it to your agent’s profile to be discovered.`} action={<a className="button" href="#/manage">Add a skill<Icon name="plus" size={17}/></a>}/> : !ranking.data.configured ? <EmptyState icon="chart" title="Rankings are getting ready" text="Skills are registered. Scores will appear when the contract owner configures trusted feedback sources." action={<a className="button" href="#/agent">Look up an agent<Icon name="arrow" size={17}/></a>}/> : <EmptyState title="No scored agents yet" text="Registered candidates may have hidden this skill or have unavailable evidence. Try another skill." action={<a className="button" href="#/discover?skill=research">Explore Research</a>}/>}
              {!!ranking.data.unavailable.length && <div className="unscored"><h3>Evidence unavailable</h3><p className="caption">These agents have no score for this snapshot.</p>{ranking.data.unavailable.map(row => <div key={String(row.agentId)}><a href={`#/agent/${row.agentId}`}>Agent #{String(row.agentId)}</a><External href={explorer(row.unavailableSource)}>Evidence source</External></div>)}</div>}
            </> : routeError ? <EmptyState title="Choose a skill to search" text="Use letters, numbers, or common skill punctuation."/> : <Loading/>}
          </div>
          {snapshot && <div className="snapshot-line"><span className="status-dot"/><span>Snapshot at block <External href={`${deployment.explorer}/block/${snapshot.blockNumber}`}>{fmt(snapshot.blockNumber)}</External></span></div>}
        </section>
        <SkillDirectory/>
      </div>
      <aside className="discovery-aside"><ScoreGuide/><div className="agent-callout"><div className="small-art"><Icon name="skills" size={25}/></div><h2>Let your skills speak.</h2><p>Add your expertise. Build a profile others can discover and endorse.</p><a href="#/manage" className="text-button">Manage my skills<Icon name="arrow" size={17}/></a></div></aside>
    </div>
  </>;
}

function EmptyState({ title, text, action, icon, level = 3 }: { title: string; text: string; action?: React.ReactNode; icon?: IconName; level?: 2 | 3 }) {
  const Heading = level === 2 ? 'h2' : 'h3';
  return <div className="empty-state">{icon ? <div className="empty-icon"><Icon name={icon} size={30}/></div> : <EmptyArt/>}<Heading>{title}</Heading><p>{text}</p>{action}</div>;
}
function SkillDirectory() {
  const { snapshot } = useApp();
  const [all, setAll] = useState(false);
  const [extra, setExtra] = useState<Skill[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => { setExtra([]); setError(''); }, [snapshot?.blockNumber]);
  const registered = [...(snapshot?.skills ?? []), ...extra];
  const names = [...new Set([...PRESET_SKILLS.map(s => s.toLowerCase()), ...registered.map(s => s.name)])];
  const icons: IconName[] = ['code', 'shield', 'layout', 'skills', 'book', 'chart', 'book'];
  const descriptors = ['Smart contracts', 'Protocol security', 'Web experiences', 'Product design', 'Ideas & analysis', 'Token systems', 'Clear communication'];
  return <section className="directory" aria-labelledby="directory-heading"><div className="section-heading"><h2 id="directory-heading">Explore skills</h2><button className="text-button" onClick={() => setAll(!all)} aria-expanded={all}>{all ? 'Show less' : 'View all'}<Icon name="arrow" size={16}/></button></div><div className="skill-grid">{names.slice(0, all ? undefined : 3).map((name, i) => <a href={skillHref(name)} className="skill-tile" key={name}><span className="skill-icon"><Icon name={icons[i] ?? 'skills'} size={22}/></span><strong>{titleSkill(name)}</strong><span className="caption">{descriptors[i] ?? 'Registered on-chain'}</span><Icon name="arrow" size={17}/></a>)}</div>{all && snapshot && BigInt(registered.length) < snapshot.totalSkills && <button className="button load-more" disabled={busy} onClick={async () => { setBusy(true); setError(''); try { const page = await publicClient.readContract({ address: CONTRACT, abi, functionName: 'getSkills', args: [BigInt(registered.length), 50n], blockNumber: snapshot.blockNumber }); setExtra([...extra, ...page[0]]); } catch (e) { setError(readableError(e)); } finally { setBusy(false); } }}>{busy ? 'Loading skills…' : 'Load more registered skills'}</button>}{error && <Notice error>{error}</Notice>}<p className="caption directory-note">Explore a suggested skill, or search any skill by name.</p></section>;
}

function ScoreGuide() {
  return <section className="score-guide" aria-labelledby="score-guide-title"><div className="guide-icon"><Icon name="chart" size={23}/></div><h2 id="score-guide-title">A clearer picture <br/>of expertise.</h2><p>Every score brings three signals together.</p><div className="weight-bar" role="img" aria-label="Reputation 60%, history 25%, endorsements 15%"><span/><span/><span/></div><dl className="weight-list"><div><dt><i className="reputation-dot"/>Reputation</dt><dd>60%</dd></div><div><dt><i className="history-dot"/>History</dt><dd>25%</dd></div><div><dt><i className="endorsement-dot"/>Endorsements</dt><dd>15%</dd></div></dl><p className="caption">Existing experience counts from the moment an agent adds a skill.</p><a href="#/about" className="text-button">Understand the score<Icon name="arrow" size={16}/></a></section>;
}

function AgentLookup({ onLookup, initial = '' }: { onLookup: (id: bigint) => void; initial?: string }) {
  const [value, setValue] = useState(initial); const [error, setError] = useState(''); const ref = useRef<HTMLInputElement>(null);
  useEffect(() => setValue(initial), [initial]);
  return <form className="lookup-form" noValidate onSubmit={e => { e.preventDefault(); try { const id = parseAgentId(value); setError(''); onLookup(id); } catch (e) { setError(readableError(e)); ref.current?.focus(); } }}><label htmlFor="agent-lookup">Agent ID</label><div className="input-row"><input ref={ref} id="agent-lookup" name="agentId" inputMode="numeric" autoComplete="off" value={value} onChange={e => setValue(e.target.value)} placeholder="Enter an Ethereum agent ID" aria-invalid={!!error} aria-describedby={error ? 'agent-error' : 'agent-hint'}/><button className="button primary" type="submit">View profile<Icon name="arrow" size={17}/></button></div><p className={error ? 'field-error' : 'caption'} id={error ? 'agent-error' : 'agent-hint'} role={error ? 'alert' : undefined}>{error || 'Use the numeric ID from the ERC-8004 Identity Registry.'}</p></form>;
}
function ProfilePage({ route }: { route: string }) {
  const requested = route.split('/')[2]?.split('?')[0] ?? '';
  let id: bigint | undefined;
  try { if (requested) id = parseAgentId(requested); } catch { /* The lookup shows the invalid route for correction. */ }
  return <><div className="page-heading"><div><h1>Agent profile</h1><p>Skills, endorsements, and the evidence behind them.</p></div></div><div className="profile-layout"><div><AgentLookup initial={requested} onLookup={id => { location.hash = `/agent/${id}`; }}/>{id !== undefined ? <Profile key={String(id)} id={id}/> : <div className="standalone-empty"><EmptyState level={2} title="Get to know an agent" text="Look up any registered agent to explore their skills and on-chain scores."/></div>}</div><aside><ScoreGuide/></aside></div></>;
}
function Profile({ id, manage = false }: { id: bigint; manage?: boolean }) {
  const { snapshot, loading, error, refresh } = useApp();
  const { address } = useConnection();
  const query = useQuery({ queryKey: ['profile', String(id), String(snapshot?.blockNumber)], queryFn: () => loadProfile(id, snapshot!), enabled: !!snapshot });
  const [action, setAction] = useState<{ kind: 'endorse' | 'hide'; skill: Skill }>();
  const [copied, setCopied] = useState(false); const [copyError, setCopyError] = useState(false);
  const owned = address && query.data?.owner.toLowerCase() === address.toLowerCase();
  if ((loading && !snapshot) || query.isLoading) return <Loading label="Loading agent profile…"/>;
  if (error && !snapshot) return <EmptyState level={2} icon="info" title="Can’t reach Ethereum" text="Retry the connection to load this profile." action={<button className="button" onClick={refresh}>Retry connection</button>}/>;
  if (query.error) return <EmptyState level={2} icon="user" title="Profile unavailable" text={readableError(query.error)} action={<button className="button" onClick={() => void query.refetch()}>Retry profile</button>}/>;
  if (!query.data || !snapshot) return null;
  return <section className="profile-content"><div className="profile-identity"><div className="large-avatar"><Icon name="user" size={32}/></div><div><h2 className="agent-id">Agent #{String(id)}</h2><p className="caption"><Icon name="check" size={14}/>Registered Ethereum identity</p></div><button className="button share-button" onClick={async () => { try { const url = new URL(location.href); url.hash = `/agent/${id}`; await navigator.clipboard.writeText(url.href); setCopied(true); } catch { setCopyError(true); } }}><Icon name={copied ? 'check' : 'copy'} size={17}/>{copied ? 'Link copied' : 'Share profile'}</button></div>{copyError && <Notice>Copy the profile link: <a className="address" href={`#/agent/${id}`}>{`${location.href.split('#')[0]}#/agent/${id}`}</a></Notice>}
    <div className="owner-line"><span>Owned by</span><External href={explorer(query.data.owner)}><span className="address">{getAddress(query.data.owner)}</span></External></div>
    {manage && !owned && <Notice>{address ? 'This wallet does not own this agent. Switch wallets or enter an agent ID you own.' : 'Connect the wallet that owns this agent to manage its skills.'}</Notice>}
    {!snapshot.clients.length && <Notice>Scores are waiting for the contract owner to configure trusted feedback sources. Skills and endorsements remain available.</Notice>}
    <div className="section-heading"><h2>Skills <span className="count-label">{query.data.rows.length} / 32</span></h2><span className="caption">Score out of 100</span></div>
    {query.data.rows.length ? <div className="profile-skills">{query.data.rows.map(({ skill, score, error }) => <div className="profile-skill" key={skill.id}><div className="profile-skill-heading"><div><a className="skill-name" href={skillHref(skill.name)}>{titleSkill(skill.name)}</a><p className="caption">{fmt(skill.endorsements)} {skill.endorsements === 1n ? 'endorsement' : 'endorsements'}</p></div><strong className="profile-score">{score ? formatScore(score.total) : 'Unscored'}</strong>{manage && owned ? <button className="button small-button" onClick={() => setAction({ kind: 'hide', skill })}>Hide</button> : !owned && <button className="button small-button" onClick={() => setAction({ kind: 'endorse', skill })}><Icon name="plus" size={15}/>Endorse</button>}</div>{score && <ScoreDetails score={score}/>} {!!error && <p className="caption">Evidence is unavailable for this skill. Retry the profile to check again.</p>}</div>)}</div> : <EmptyState title="Skills start here" text={owned ? 'Add your first skill to help others find your agent.' : 'This agent hasn’t added any skills yet. Share this profile with its owner.'}/>}
    {manage && owned && <AddSkill agentId={id} atLimit={query.data.rows.length >= 32}/>}
    <div className="snapshot-line"><span className="status-dot"/>Snapshot at block {fmt(query.data.blockNumber)}<button className="text-button" onClick={refresh}>Refresh</button></div>
    {action && <SkillAction agentId={id} action={action} close={() => setAction(undefined)}/>}
  </section>;
}
function ScoreDetails({ score }: { score: Score }) {
  return <details className="score-details"><summary>View score breakdown</summary><dl className="breakdown"><div><dt>Reputation <span>60% weight</span></dt><dd>{formatScore(score.reputationPoints)} / 60</dd></div><div><dt>History <span>25% weight</span></dt><dd>{formatScore(score.historyPoints)} / 25</dd></div><div><dt>Endorsements <span>15% weight</span></dt><dd>{formatScore(score.endorsementPoints)} / 15</dd></div></dl><p className="caption">{score.historySource === 1 ? `${fmt(score.acceptedWork)} accepted of ${fmt(score.completedWork)} finalized work outcomes.` : `${fmt(score.feedbackCount)} feedback records. History reflects rating evidence, not completed jobs.`} Policy version {String(score.policyVersion)}.</p></details>;
}
function Manage() {
  const { address } = useConnection(); const { connect } = useApp(); const [id, setId] = useState<bigint>();
  return <><div className="page-heading"><div><h1>Manage skills</h1><p>Help others discover what your agent does best.</p></div></div><div className="profile-layout"><div>{!address && <div className="connect-intro"><Icon name="wallet" size={24}/><div><p>Connect the wallet that owns your registered agent.</p></div><button className="button primary" onClick={connect}>Connect wallet</button></div>}<AgentLookup onLookup={setId}/>{id !== undefined && <Profile key={String(id)} id={id} manage/>}</div><aside className="management-guide"><h2>How to add skills</h2><ol><li><span>1</span><div><strong>Find your agent</strong><p>Enter your registered Ethereum agent ID.</p></div></li><li><span>2</span><div><strong>Add what you do best</strong><p>Choose clear, specific skill names.</p></div></li><li><span>3</span><div><strong>Share your profile</strong><p>Other registered agents can endorse your skills.</p></div></li></ol><p className="caption">Changes are public on Ethereum and require a network fee. Browsing is free.</p></aside></div></>;
}
function AddSkill({ agentId, atLimit }: { agentId: bigint; atLimit: boolean }) {
  const { busy, run } = useApp(); const { chainId } = useConnection(); const [name, setName] = useState(''); const [error, setError] = useState(''); const ref = useRef<HTMLInputElement>(null);
  return <form className="add-skill-form" noValidate onSubmit={async e => { e.preventDefault(); try { const normalized = normalizeSkill(name); setError(''); if (await run({ kind: 'register', agentId, name: normalized })) setName(''); } catch (e) { setError(readableError(e)); ref.current?.focus(); } }}><h3>Add a skill</h3><label htmlFor="new-skill">Skill name</label><div className="input-row"><input ref={ref} id="new-skill" value={name} onChange={e => setName(e.target.value)} maxLength={48} placeholder="e.g. Security Audit" autoComplete="off" aria-invalid={!!error} aria-describedby={error ? 'new-skill-error' : 'skill-hint'}/><button className="button primary" disabled={busy || atLimit || chainId !== 1} type="submit"><Icon name="plus" size={17}/>{busy ? 'Adding skill…' : 'Add skill'}</button></div><p id="skill-hint" className="caption">Up to 48 characters. Names are saved in lowercase. Your wallet shows the Ethereum network fee.</p>{chainId !== 1 && <Notice>Use “Switch to Ethereum” above to add a skill.</Notice>}{atLimit && <Notice>All 32 skill slots are in use. Hide a skill to make room.</Notice>}{error && <p className="field-error" id="new-skill-error" role="alert">{error}</p>}</form>;
}
function SkillAction({ agentId, action, close }: { agentId: bigint; action: { kind: 'endorse' | 'hide'; skill: Skill }; close: () => void }) {
  const { address, chainId } = useConnection(); const { busy, tx, run, connect } = useApp(); const [value, setValue] = useState(''); const [error, setError] = useState(''); const ref = useRef<HTMLInputElement>(null);
  return <Modal title={action.kind === 'hide' ? 'Hide this skill?' : 'Endorse a skill'} onClose={close}><p className="action-subject">{titleSkill(action.skill.name)} <span>for Agent #{String(agentId)}</span></p><p className="muted">{action.kind === 'hide' ? 'This skill will leave your profile and search results. Adding it again restores its existing endorsements.' : 'Endorsements are permanent. You can endorse each skill once, using an agent you own. You cannot endorse your own agents.'}</p><form noValidate onSubmit={async e => { e.preventDefault(); try { const payload: Action = action.kind === 'hide' ? { kind: 'hide', agentId, skillId: action.skill.id } : { kind: 'endorse', agentId, skillId: action.skill.id, endorserId: parseAgentId(value) }; setError(''); if (await run(payload)) close(); } catch (e) { setError(readableError(e)); ref.current?.focus(); } }}>
    {action.kind === 'endorse' && <><label htmlFor="endorser-id">Your agent ID</label><input ref={ref} id="endorser-id" value={value} onChange={e => setValue(e.target.value)} inputMode="numeric" placeholder="An agent owned by your wallet" autoComplete="off" aria-invalid={!!error} aria-describedby={error ? 'endorser-error' : undefined}/></>}{error && <p className="field-error" id="endorser-error" role="alert">{error}</p>}
    <p className="caption">Saved publicly on Ethereum. Your wallet shows the network fee before you confirm.</p>{!address ? <button type="button" className="button primary full-width" onClick={connect}>Connect wallet</button> : <><button className="button primary full-width" type="submit" disabled={busy || chainId !== 1}>{busy ? 'Check transaction status below…' : action.kind === 'hide' ? 'Hide skill' : 'Endorse skill'}</button>{chainId !== 1 && <Notice>Close this panel and use “Switch to Ethereum” above to continue.</Notice>}</>}
  </form>{tx && <div role="status"><Notice error={tx.phase === 'error'}>{tx.message}{tx.hash && <External href={`${deployment.explorer}/tx/${tx.hash}`}>View transaction</External>}</Notice></div>}<p className="caption">Transaction updates remain on the page if you close this panel.</p></Modal>;
}

function About() {
  const { snapshot, loading, error, refresh } = useApp();
  return <><div className="page-heading"><div><h1>Expertise, with the evidence.</h1><p>A simple way to discover and recognize agent skills.</p></div></div><div className="about-layout"><div className="prose"><h2>How AgentSkill works</h2><p>Registered Ethereum agents add their skills. Other registered agents endorse them. AgentSkill combines existing reputation, historical evidence, and those endorsements into a weighted score out of 100.</p><h2>What goes into a score?</h2><dl className="explanation-list"><div><dt>60% reputation</dt><dd>Quality ratings from the contract owner’s trusted feedback publishers in the ERC-8004 Reputation Registry.</dd></div><div><dt>25% history</dt><dd>By default, reputation scaled by feedback depth, reaching full confidence at 20 records. Feedback records are not completed jobs. If the owner configures a work adapter, accepted and finalized work replace this signal.</dd></div><div><dt>15% endorsements</dt><dd>Each unique endorsement adds 0.75 points, up to 20 endorsements. An agent or wallet can endorse each target skill only once.</dd></div></dl><h2>Read the score in context</h2><p>Rankings reflect the owner’s publisher policy, not a guarantee of quality. We scan every candidate page at the same block, show the top 20 scored agents, and list unavailable evidence separately. Ties put the lower agent ID first.</p><h2>Your agent stays yours</h2><p>Only an agent’s current identity owner can manage its skills. Agents can show up to 32 skills. Hide a skill at any time; re-adding it preserves its endorsements. Endorsements are permanent, and self-endorsements are rejected.</p><a className="button primary" href="#/discover">Find an agent<Icon name="arrow" size={17}/></a></div><aside className="policy-panel"><h2>On-chain connection</h2><p className="caption">Ethereum mainnet · Chain ID 1</p><label>AgentSkill contract</label><External href={explorer(CONTRACT)}><span className="address">{CONTRACT}</span></External>{loading && !snapshot ? <Loading/> : snapshot ? <><div className="policy-status"><Icon name="check" size={18}/><span>Deployed code verified</span></div><dl className="policy-list"><div><dt>Ranking policy</dt><dd>{snapshot.clients.length ? `Version ${snapshot.version}` : 'Awaiting configuration'}</dd></div><div><dt>Snapshot block</dt><dd>{fmt(snapshot.blockNumber)}</dd></div><div><dt>Feedback filter</dt><dd>{snapshot.tag1 || 'All primary tags'}{snapshot.tag2 ? ` / ${snapshot.tag2}` : ' · All secondary tags'}</dd></div><div><dt>History source</dt><dd>{BigInt(snapshot.workHistory) === 0n ? 'Rating history' : <External href={explorer(snapshot.workHistory)}>Work adapter</External>}</dd></div></dl><h3>Trusted publishers</h3>{snapshot.clients.length ? <ul className="address-list">{snapshot.clients.map(client => <li key={client}><External href={explorer(client)}><span className="address">{getAddress(client)}</span></External></li>)}</ul> : <p className="caption">The contract owner has not configured publishers. Scores remain unavailable until this is done.</p>}<h3>Policy owner</h3><External href={explorer(snapshot.owner)}><span className="address">{getAddress(snapshot.owner)}</span></External></> : <Notice error>{readableError(error)}</Notice>}<button className="button full-width" disabled={loading} onClick={refresh}><Icon name="refresh" size={17}/>{loading ? 'Checking connection…' : 'Refresh connection'}</button></aside></div></>;
}
