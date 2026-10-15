// Isolated test fixtures only. RPC and wallet requests are intercepted; no transaction is broadcast.
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { chromium, webkit } from 'playwright';
import AxeBuilder from '@axe-core/playwright';
import { decodeFunctionData, encodeFunctionResult, encodeErrorResult, keccak256, stringToHex, parseAbi } from 'viem';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:http';
import { resolve, extname } from 'node:path';
const root=fileURLToPath(new URL('../../../', import.meta.url));
process.chdir(root);
const artifact=JSON.parse(readFileSync('out/AgentSkill.sol/AgentSkill.json'));
const {abi}=artifact;
const deployment=JSON.parse(readFileSync('web/dashboard/src/deployment.json'));
const mime={'.html':'text/html','.js':'text/javascript','.css':'text/css','.woff2':'font/woff2','.svg':'image/svg+xml','.png':'image/png'};
const dist=resolve(root,'dist');
const server=createServer((req,res)=>{
 try {
  const pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
  if(!pathname.startsWith('/preview/')){res.writeHead(404);res.end();return;}
  const path=resolve(dist,pathname.slice('/preview/'.length)||'index.html');
  if(!path.startsWith(dist+'/')){res.writeHead(403);res.end();return;}
  const data=readFileSync(path);res.writeHead(200,{'Content-Type':mime[extname(path)]||'application/octet-stream'});res.end(data);
 }catch{res.writeHead(404);res.end();}
});
await new Promise(done=>server.listen(0,'127.0.0.1',done));
const base=`http://127.0.0.1:${server.address().port}/preview/`;
const block=26191312n;
const OWNER='0x1111111111111111111111111111111111111111';
const PEER='0x2222222222222222222222222222222222222222';
const IDENTITY='0x8004A169FB4a3325136EB29fA0ceB6D2e539a432';
const ZERO='0x'+'0'.repeat(40);
const HASH='0x'+'a'.repeat(64);
const BLOCKHASH='0x'+'b'.repeat(64);
const skill={id:keccak256(stringToHex('solidity')),name:'solidity',endorsements:3n};
const score=(id=1n)=>({total:id>=40n?9500n:7000n+id*20n,reputationPoints:5400n,historyPoints:2250n,endorsementPoints:225n,reputationBps:9000n,historyBps:9000n,endorsements:3n,feedbackCount:20n,reputationValue:90n,reputationDecimals:0,completedWork:0n,acceptedWork:0n,historySource:0,policyVersion:1n});
const results=[];
const pass=(name)=>{results.push({name,passed:true});console.log('PASS',name)};
let browser;
try { browser=await (process.env.TEST_ENGINE==='webkit'?webkit:chromium).launch(); } catch(error) {server.close();throw error;}
mkdirSync('test/scratch/evidence',{recursive:true});
async function setup(options={}) {
 const ctx=await browser.newContext({viewport:{width:390,height:844},...options.context});
 const state={configured:true,offline:false,badCode:false,wrongRpc:false,empty:false,failPage:false,rejectTransaction:false,revertTransaction:false,rejectSim:false,skills:[{...skill}],calls:[],sent:[],...options};
 const page=await ctx.newPage();globalThis.lastPage=page;
 const jsErrors=[];page.on('pageerror',e=>jsErrors.push(e.message));
 await ctx.route(/https:\/\/(ethereum-rpc\.publicnode\.com|eth\.drpc\.org)/,async route=>{
  if(state.offline || (state.firstRpcDown && route.request().url().includes('publicnode'))) return route.abort('failed');
  const request=route.request().postDataJSON();
  async function respond(rpc) {
   const {method,params=[]}=rpc;state.calls.push({method,params});
   let result;
   try {
    if(method==='eth_chainId') result=state.wrongRpc?'0x2':'0x1';
    else if(method==='eth_getCode') result=state.badCode?'0x6000':artifact.deployedBytecode.object;
    else if(method==='eth_blockNumber') result='0x'+(block+BigInt(state.sent.length)).toString(16);
    else if(method==='eth_getTransactionReceipt') result={transactionHash:HASH,transactionIndex:'0x0',blockHash:BLOCKHASH,blockNumber:'0x'+(block+BigInt(state.sent.length)).toString(16),from:OWNER,to:deployment.contractAddress,cumulativeGasUsed:'0x10000',gasUsed:'0x10000',contractAddress:null,logs:[],logsBloom:'0x'+'0'.repeat(512),status:state.revertTransaction?'0x0':'0x1',effectiveGasPrice:'0x1',type:'0x2'};
    else if(method==='eth_getTransactionByHash') result={hash:HASH,nonce:'0x1',blockHash:BLOCKHASH,blockNumber:'0x'+block.toString(16),transactionIndex:'0x0',from:OWNER,to:deployment.contractAddress,value:'0x0',gas:'0x30000',gasPrice:'0x1',input:'0x',type:'0x2',chainId:'0x1'};
    else if(method==='eth_call') {
     const identity=String(params[0].to).toLowerCase()===IDENTITY.toLowerCase();
     const callAbi=identity?parseAbi(['function ownerOf(uint256) view returns(address)']):abi;
     const {functionName:name,args=[]}=decodeFunctionData({abi:callAbi,data:params[0].data});
     state.calls.at(-1).functionName=name;state.calls.at(-1).decodedArgs=args.map(String);
     let output;
     if(name==='getTrustedClients')output=state.configured?[PEER]:[];
     else if(name==='policyVersion')output=1n;
     else if(name==='reputationTag1'||name==='reputationTag2')output='';
     else if(name==='workHistory')output=ZERO;
     else if(name==='IDENTITY_REGISTRY')output=IDENTITY;
     else if(name==='owner')output=PEER;
     else if(name==='getSkills')output=[[skill],1n];
     else if(name==='skillAgentCount')output=state.empty?0n:41n;
     else if(name==='getTopAgents') {
      if(state.failPage && args[1]>0n)throw new Error('later page unavailable');
      const start=Number(args[1]);const end=Math.min(start+20,41);
      const entries=Array.from({length:end-start},(_,i)=>{const id=BigInt(start+i+1);return {agentId:id,score:score(id),unavailable:id===18n,unavailableSource:PEER}}).sort((a,b)=>a.score.total===b.score.total?Number(a.agentId-b.agentId):Number(b.score.total-a.score.total));
      output=[entries,BigInt(end),41n];
     }
     else if(name==='getAgentSkills') {
      if(args[0]===999n) return {jsonrpc:'2.0',id:rpc.id,error:{code:3,message:'execution reverted',data:encodeErrorResult({abi,errorName:'UnregisteredAgent',args:[999n]})}};
      output=state.skills;
     }
     else if(name==='ownerOf')output=args[0]===7n?OWNER:PEER;
     else if(name==='getScoreBreakdown')output=score(args[0]);
     else if(['registerSkill','endorseSkill','hideSkill'].includes(name)) {
      if(state.rejectSim) return {jsonrpc:'2.0',id:rpc.id,error:{code:3,message:'execution reverted',data:encodeErrorResult({abi,errorName:'DuplicateEndorsement'})}};
      output=name==='registerSkill'?keccak256(stringToHex(args[1])):undefined;
     }
     else throw new Error('unhandled contract method '+name);
     result=encodeFunctionResult({abi:callAbi,functionName:name,result:output});
    } else throw new Error('unhandled RPC method '+method);
    return {jsonrpc:'2.0',id:rpc.id,result};
   } catch(e) {return {jsonrpc:'2.0',id:rpc.id,error:{code:-32000,message:String(e)}};}
  }
  const response=Array.isArray(request)?await Promise.all(request.map(respond)):await respond(request);
  await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(response)});
 });
 if(options.wallet) {
  await page.exposeFunction('__captureTransaction',tx=>{
   state.sent.push(tx);
   if(!state.revertTransaction){const {functionName,args}=decodeFunctionData({abi,data:tx.data});if(functionName==='registerSkill')state.skills.push({id:keccak256(stringToHex(args[1])),name:args[1],endorsements:0n});if(functionName==='hideSkill')state.skills=state.skills.filter(s=>s.id!==args[1]);}
   return HASH;
  });
  await page.addInitScript(({owner,chainId,requireAdd,rejectTx})=>{
   let connected=false,chain=chainId;const listeners={};
   window.__wallet={calls:[],rejectTx};
   const emit=(event,value)=>(listeners[event]??[]).forEach(fn=>fn(value));
   const provider={on:(event,fn)=>{(listeners[event]??=[]).push(fn)},removeListener:(event,fn)=>{listeners[event]=(listeners[event]??[]).filter(x=>x!==fn)},request:async({method,params})=>{
    window.__wallet.calls.push({method,params});
    if(method==='eth_chainId')return chain;
    if(method==='eth_accounts')return connected?[owner]:[];
    if(method==='eth_requestAccounts'){connected=true;return[owner]}
    if(method==='wallet_requestPermissions')return[{parentCapability:'eth_accounts'}];
    if(method==='wallet_revokePermissions'){connected=false;return null}
    if(method==='wallet_switchEthereumChain'){if(requireAdd){requireAdd=false;throw Object.assign(new Error('Unknown chain'),{code:4902})}chain=params[0].chainId;emit('chainChanged',chain);return null}
    if(method==='wallet_addEthereumChain'){chain=params[0].chainId;emit('chainChanged',chain);return null}
    if(method==='eth_sendTransaction'){if(window.__wallet.rejectTx)throw Object.assign(new Error('User rejected'),{code:4001});return await window.__captureTransaction(params[0])}
    throw Object.assign(new Error('Unsupported '+method),{code:-32601});
   }};
   window.ethereum=provider;
   const announce=()=>window.dispatchEvent(new CustomEvent('eip6963:announceProvider',{detail:{info:{uuid:'5bf794d8-c447-4e89-9170-8decfa23c1a1',name:'Test wallet',icon:'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="28" height="28"><rect width="28" height="28" fill="green"/></svg>',rdns:'test.local'},provider}}));
   window.addEventListener('eip6963:requestProvider',announce);announce();
  },{owner:OWNER,chainId:options.chainId??'0x1',requireAdd:!!options.requireAdd,rejectTx:!!options.rejectTransaction});
 }
 await page.goto(base);
 return {ctx,page,state,jsErrors};
}
async function connect(page){await page.getByRole('button',{name:'Connect',exact:true}).click();await page.getByRole('button',{name:'Test wallet',exact:false}).click();await page.getByRole('dialog').waitFor({state:'hidden'});}
async function waitResults(page){await page.locator('.ranking-list').waitFor();}
try {
 for(const empty of [true,false]) {
  const {ctx,page,state}=await setup({empty});
  const longSkill='s'.repeat(48);
  await page.getByLabel('What skill are you looking for?').fill(longSkill);
  await page.getByRole('button',{name:'Search',exact:true}).click();
  if(empty)await page.getByRole('heading',{name:'Room for your expertise'}).waitFor();else await waitResults(page);
  await page.waitForFunction(()=>document.querySelector('.results-section')?.getAttribute('aria-busy')==='false');
  await page.evaluate(()=>document.fonts.ready);
  for(const width of [320,390,1440]) {
   await page.setViewportSize({width,height:844});
   const layout=await page.evaluate(()=>{
    const card=document.querySelector('.results-section').getBoundingClientRect();
    const heading=document.querySelector('#results-heading');
    const refresh=document.querySelector('[aria-label="Refresh agent rankings"]').getBoundingClientRect();
    const textNodes=[heading,...document.querySelectorAll('.empty-state p,.ranking-row .agent-name .caption')];
    const textInsideCard=textNodes.every(node=>{
     const range=document.createRange();range.selectNodeContents(node);
     return [...range.getClientRects()].every(rect=>rect.left>=card.left && rect.right<=card.right);
    });
    return {pageWidth:document.documentElement.scrollWidth,heading:heading.textContent,description:document.querySelector('.empty-state p')?.textContent,textInsideCard,refreshInsideCard:refresh.left>=card.left && refresh.right<=card.right,headingBeforeRefresh:heading.getBoundingClientRect().right<=refresh.left};
   });
   assert.equal(layout.pageWidth,width,`${empty?'empty':'populated'} long-skill results overflow at ${width}px`);
   assert.equal(layout.heading.toLowerCase(),`${longSkill} agents`);
   if(empty)assert.ok(layout.description.includes(longSkill));
   assert.ok(layout.textInsideCard,`Full skill text must wrap inside the card at ${width}px`);
   assert.ok(layout.refreshInsideCard && layout.headingBeforeRefresh,`Refresh must remain visible beside the heading at ${width}px`);
  }
  const reads=state.calls.filter(c=>c.method==='eth_blockNumber').length;
  await page.getByRole('button',{name:'Refresh agent rankings'}).click();
  await page.waitForFunction(()=>document.querySelector('.results-section')?.getAttribute('aria-busy')==='false');
  assert.ok(state.calls.filter(c=>c.method==='eth_blockNumber').length>reads);
  pass(`48-character skill wraps without clipping in ${empty?'empty':'populated'} results at 320, 390, 1440; Refresh stays usable`);
  await ctx.close();
 }
 {
  const {ctx,page,state,jsErrors}=await setup();await waitResults(page);
  assert.deepEqual(await page.locator('.ranking-row .agent-name').allTextContents().then(a=>a.slice(0,2)),['Agent #40Solidity','Agent #41Solidity']);
  assert.equal(await page.locator('.ranking-row').count(),20);
  assert.match(await page.locator('.unscored').innerText(),/Agent #18/);
  const calls=state.calls.filter(c=>c.functionName==='getTopAgents');assert.deepEqual(calls.map(c=>c.decodedArgs[1]),['0','20','40']);assert.equal(new Set(calls.map(c=>c.params[1])).size,1);
  pass('Global top 20 includes later-page winners, numeric tie break, unavailable agents, same-block pagination');
  await page.getByLabel('What skill are you looking for?').fill('  Security   AUDIT  ');await page.getByRole('button',{name:'Search',exact:true}).click();await page.getByRole('heading',{name:'Security Audit agents'}).waitFor();assert.match(page.url(),/security%20audit/);pass('Search canonicalizes labels and updates shareable hash route');
  await page.getByLabel('What skill are you looking for?').fill('!!!');await page.getByRole('button',{name:'Search',exact:true}).click();assert.equal(await page.getByLabel('What skill are you looking for?').getAttribute('aria-invalid'),'true');pass('Invalid search gives inline error and focuses input');
  await page.getByRole('button',{name:'View all',exact:true}).click();assert.equal(await page.locator('.skill-tile').count(),7);pass('Skill directory expands and collapses');
  await page.goto(base+'#/agent/40');await page.getByRole('heading',{name:'Agent #40',exact:true}).waitFor();await page.getByText('View score breakdown',{exact:true}).click();assert.match(await page.locator('.score-details').innerText(),/20 feedback records/);pass('Profile loads skills, scores, policy version and feedback semantics');
  await page.getByRole('button',{name:'Endorse',exact:true}).click();assert.match(await page.getByRole('dialog').innerText(),/permanent/);assert.equal(await page.getByRole('dialog').getByRole('button',{name:'Connect wallet'}).count(),1);await page.keyboard.press('Escape');assert.equal(await page.evaluate(()=>document.activeElement.textContent.trim()),'Endorse');pass('Endorsement explains permanence, gates connection, Escape restores focus');
  await page.goto(base+'#/agent/999');await page.getByRole('heading',{name:'Profile unavailable'}).waitFor();assert.match(await page.locator('.profile-layout').innerText(),/not registered/);pass('Unregistered identity shows a useful error, never a fabricated profile');
  await page.goto(base);await waitResults(page);
  for(const width of [320,390,768,1024,1440]){await page.setViewportSize({width,height:900});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);}
  await page.setViewportSize({width:390,height:844});const ax=await new AxeBuilder({page}).analyze();assert.deepEqual(ax.violations.map(v=>({id:v.id,nodes:v.nodes.length})),[]);pass('Populated results reflow at 320, 390, 768, 1024, 1440; axe reports zero violations');
  assert.deepEqual(jsErrors,[]);pass('No JavaScript errors in populated search/profile flows');await ctx.close();
 }
 {
  const {ctx,page}=await setup();await waitResults(page);await page.goto(base+'#/agent');await page.reload();await page.locator('h1').waitFor();
  await page.keyboard.press('Tab');assert.equal(await page.evaluate(()=>document.activeElement.textContent.trim()),'Skip to content');
  await page.keyboard.press('Enter');assert.ok(page.url().endsWith('#/agent'));assert.equal(await page.evaluate(()=>document.activeElement.id),'main');
  await page.keyboard.press('Tab');await page.keyboard.type('40');await page.keyboard.press('Tab');await page.keyboard.press('Enter');
  await page.getByRole('heading',{name:'Agent #40',exact:true}).waitFor();pass('Keyboard skip link preserves the route; keyboard-only profile lookup completes');
  await page.getByRole('button',{name:'Endorse',exact:true}).click();
  await page.getByRole('dialog').getByRole('button',{name:'Connect wallet',exact:true}).click();
  const titles=await page.locator('dialog[open]').evaluateAll(nodes=>nodes.map(n=>({label:n.getAttribute('aria-labelledby'),title:document.getElementById(n.getAttribute('aria-labelledby')).textContent})));
  assert.equal(new Set(titles.map(t=>t.label)).size,2);assert.deepEqual(titles.map(t=>t.title).sort(),['Connect a wallet','Endorse a skill']);
  for(let i=0;i<8;i++){await page.keyboard.press('Tab');assert.equal(await page.evaluate(()=>document.activeElement.closest('dialog')?.querySelector('h2').textContent),'Connect a wallet');}
  await page.keyboard.press('Escape');assert.equal(await page.locator('dialog[open]').count(),1);pass('Nested wallet and endorsement dialogs have unique names and keep keyboard focus trapped');
  await page.keyboard.press('Escape');await ctx.close();
 }
 {
  const {ctx,page}=await setup({configured:false});await page.getByRole('heading',{name:'Rankings are getting ready'}).waitFor();assert.equal(await page.locator('.ranking-row').count(),0);pass('Unconfigured publisher policy has an honest non-scored state');await ctx.close();
 }
 {
  const {ctx,page}=await setup({empty:true});await page.getByRole('heading',{name:'Room for your expertise'}).waitFor();await page.getByRole('link',{name:'Add a skill',exact:true}).click();await page.getByRole('heading',{name:'Manage skills'}).waitFor();pass('Empty result offers working add-skill navigation');await ctx.close();
 }
 {
  const {ctx,page,state}=await setup({offline:true});await page.getByRole('heading',{name:'Can’t reach Ethereum'}).waitFor();state.offline=false;await page.getByRole('button',{name:'Retry connection'}).click();await waitResults(page);pass('Offline read failure recovers with retry');await ctx.close();
 }
 {
  const {ctx,page,state}=await setup({firstRpcDown:true});await waitResults(page);assert.ok(state.calls.length>5);pass('Secondary pinned RPC handles primary RPC failure');await ctx.close();
 }
 {
  const {ctx,page}=await setup({failPage:true});await page.getByRole('heading',{name:'This search couldn’t finish'}).waitFor();assert.equal(await page.locator('.ranking-row').count(),0);pass('Failed later page does not present partial results as global rankings');await ctx.close();
 }
 for(const field of ['badCode','wrongRpc']){
  const {ctx,page}=await setup({[field]:true});await page.getByRole('heading',{name:'Can’t reach Ethereum'}).waitFor();assert.equal(await page.locator('.ranking-row').count(),0);pass(field==='badCode'?'Unexpected runtime bytecode blocks contract reads':'Wrong RPC chain blocks contract reads');await ctx.close();
 }
 {
  const {ctx,page,state}=await setup({wallet:true,chainId:'0x89',requireAdd:true});await waitResults(page);await connect(page);await page.getByRole('button',{name:'Switch to Ethereum',exact:true}).click();await page.getByRole('button',{name:/0x1111/}).waitFor();
  const calls=await page.evaluate(()=>window.__wallet.calls);assert.ok(calls.some(c=>c.method==='wallet_addEthereumChain' && c.params[0].chainId==='0x1'));pass('Named EIP-6963 wallet connects, wrong chain switches and 4902 adds pinned Ethereum');
  await page.goto(base+'#/manage');await page.getByLabel('Agent ID',{exact:true}).fill('7');await page.getByRole('button',{name:'View profile',exact:true}).click();await page.getByRole('heading',{name:'Agent #7',exact:true}).waitFor();await page.getByLabel('Skill name',{exact:true}).fill('  Research  ');await page.getByRole('button',{name:'Add skill',exact:true}).click();await page.getByText('Skill added. Your agent can now receive endorsements.',{exact:true}).waitFor();assert.equal(state.sent.length,1);assert.equal(state.sent[0].to.toLowerCase(),deployment.contractAddress);assert.equal(decodeFunctionData({abi,data:state.sent[0].data}).args[1],'research');pass('Owned identity adds a canonical skill through simulated and confirmed wallet transaction');
  await page.getByRole('link',{name:'Research',exact:true}).waitFor();pass('Confirmed registration refreshes the profile');
  await page.locator('.profile-skill').filter({has:page.getByRole('link',{name:'Research',exact:true})}).getByRole('button',{name:'Hide',exact:true}).click();await page.getByRole('button',{name:'Hide skill',exact:true}).click();await page.getByText('Skill hidden from your profile.',{exact:true}).waitFor();assert.equal(state.sent.length,2);pass('Hide skill confirms reversible effect and refreshes after receipt');
  await page.goto(base+'#/agent/40');await page.getByRole('heading',{name:'Agent #40',exact:true}).waitFor();await page.getByRole('button',{name:'Endorse',exact:true}).click();await page.getByLabel('Your agent ID').fill('7');await page.getByRole('button',{name:'Endorse skill',exact:true}).click();await page.getByText('Endorsement recorded. Thank you for sharing your experience.',{exact:true}).waitFor();assert.equal(state.sent.length,3);assert.deepEqual(decodeFunctionData({abi,data:state.sent[2].data}).args,[7n,40n,skill.id]);pass('Endorsement sends the correct endorser, target identity, skill and destination');
  await page.getByRole('button',{name:/0x1111/}).click();await page.getByRole('button',{name:'Disconnect',exact:true}).click();await page.getByRole('button',{name:'Connect',exact:true}).waitFor();pass('Wallet disconnect returns the header to the connect control');await ctx.close();
 }
 {
  const {ctx,page,state}=await setup({wallet:true,revertTransaction:true});await waitResults(page);await connect(page);await page.goto(base+'#/manage');await page.getByLabel('Agent ID',{exact:true}).fill('7');await page.getByRole('button',{name:'View profile',exact:true}).click();await page.getByLabel('Skill name',{exact:true}).fill('Writing');await page.getByRole('button',{name:'Add skill',exact:true}).click();await page.getByText('The transaction reverted on Ethereum. No skill change was saved.',{exact:true}).waitFor();assert.equal(state.sent.length,1);assert.equal(state.skills.length,1);pass('A reverted receipt never reports success or mutates the visible skills');await ctx.close();
 }
 {
  const {ctx,page,state}=await setup({wallet:true,rejectTransaction:true});await waitResults(page);await connect(page);await page.goto(base+'#/manage');await page.getByLabel('Agent ID',{exact:true}).fill('7');await page.getByRole('button',{name:'View profile',exact:true}).click();await page.getByLabel('Skill name',{exact:true}).fill('Writing');await page.getByRole('button',{name:'Add skill',exact:true}).click();await page.getByText('Request cancelled in your wallet. Nothing was sent.',{exact:true}).waitFor();assert.equal(state.sent.length,0);pass('Wallet rejection restores editable form without recording a transaction');await ctx.close();
 }
 {
  const {ctx,page,state}=await setup({wallet:true,rejectSim:true});await waitResults(page);await connect(page);await page.goto(base+'#/agent/40');await page.getByRole('button',{name:'Endorse',exact:true}).click();await page.getByLabel('Your agent ID').fill('7');await page.getByRole('button',{name:'Endorse skill',exact:true}).click();await page.getByRole('dialog').getByText('This agent or wallet has already endorsed that skill.',{exact:true}).waitFor();assert.equal(state.sent.length,0);pass('Duplicate endorsement rejection stays visible inside the modal before wallet signing');await ctx.close();
 }
 {
  const {ctx,page}=await setup({context:{viewport:{width:390,height:844},isMobile:true,hasTouch:true,userAgent:'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile Safari/604.1'}});await page.getByRole('button',{name:'Connect',exact:true}).click();for(const name of ['MetaMask','Coinbase Wallet','Rabby','Phantom'])assert.equal(await page.getByRole('link',{name:'Open in '+name,exact:false}).count(),1);assert.equal(await page.getByRole('button',{name:'Coinbase Smart Wallet',exact:false}).count(),1);assert.equal(await page.getByRole('button',{name:'Browser wallet',exact:false}).count(),0);const ax=await new AxeBuilder({page}).analyze();assert.deepEqual(ax.violations.map(v=>v.id),[]);pass('Phone picker offers all four deep links and Coinbase Smart Wallet; accessible dialog has no axe violations');await ctx.close();
 }
} catch(e){console.error('PAGE',await globalThis.lastPage.locator('body').innerText());console.error('WALLET',await globalThis.lastPage.evaluate(()=>window.__wallet));results.push({name:'ERROR',passed:false,error:String(e),stack:e.stack});console.error(e);process.exitCode=1;}finally{await browser.close();server.close();writeFileSync(`test/scratch/browser-results-${process.env.TEST_ENGINE||'chromium'}.json`,JSON.stringify(results,null,2)+'\n');}
