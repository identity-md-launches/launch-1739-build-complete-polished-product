import { BrowserProvider, Contract, FetchRequest, JsonRpcProvider, ZeroAddress, getAddress, id as hashId } from "./vendor/ethers.min.js";
import { CONFIG } from "./config.js";
import { PRESET_SKILLS, normalizeSkill, parseAgentId, formatScore, shortAddress, titleSkill, loadLeaderboard, safeHttpUrl, readableError } from "./core.js";

const IDENTITY = "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432";
const REPUTATION = "0x8004BAa17C55a88189AE136b182e5fdA19dE9b63";
const $ = selector => document.querySelector(selector);
const $$ = selector => [...document.querySelectorAll(selector)];
const store = {
  read(key) { try { return JSON.parse(localStorage.getItem(`agentskill:${key}`)); } catch { return null; } },
  write(key, value) { try { localStorage.setItem(`agentskill:${key}`, JSON.stringify(value)); } catch { /* Private browsing may disable storage. */ } },
};
const saved = store.read("connection");
const state = {
  config: { ...CONFIG, ...(saved && typeof saved === "object" ? { contractAddress: saved.contractAddress, rpcUrl: saved.rpcUrl } : {}) },
  provider: null, contract: null, identity: null, wallet: null, account: null, abi: null,
  epoch: 0, profileEpoch: 0, profileId: null, endorsement: null, busy: false, policy: null, dialogOrder: [],
};

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function link(text, href, className = "") {
  const node = element("a", className, text);
  node.href = href;
  node.target = "_blank";
  node.rel = "noopener noreferrer";
  return node;
}

function button(text, action, className = "button dark") {
  const node = element("button", className, text);
  node.type = "button";
  node.addEventListener("click", action);
  return node;
}

function closeDialog(dialog) { if (dialog.open) dialog.close(); }
function showDialog(selector) {
  const dialog = $(selector);
  if (dialog.open && state.dialogOrder.at(-1) === dialog) return;
  state.dialogOrder = state.dialogOrder.filter(item => item !== dialog);
  if (dialog.open) dialog.close();
  dialog.showModal();
  state.dialogOrder.push(dialog);
  placeToast();
}

function placeToast() {
  state.dialogOrder = state.dialogOrder.filter(dialog => dialog.open);
  // Native dialogs occupy the browser's top layer. Keep transaction feedback in that layer too.
  (state.dialogOrder.at(-1) || document.body).append($("#toast"));
}

function toast(message, { error = false, hash = null } = {}) {
  placeToast();
  $("#toast-text").textContent = message;
  $("#toast").classList.toggle("error", error);
  $("#toast").hidden = false;
  $("#toast-link").hidden = !hash;
  if (hash) $("#toast-link").href = `${CONFIG.explorerUrl}/tx/${hash}`;
}

function explainError(error) { return readableError(error, state.contract?.interface); }
function requireDeployment() {
  if (!state.contract) throw new Error("Set up your AgentSkill deployment in Connection first. Browsing does not require a wallet.");
}

function markLoading() {
  $("#results").replaceChildren();
  const lines = element("div", "loading-lines");
  for (let i = 0; i < 3; i++) lines.append(element("div", "skeleton"));
  $("#results").append(lines);
  $("#results").setAttribute("aria-busy", "true");
}

function emptyResults(title, message, actionText, action) {
  const block = element("div", "empty-state");
  block.append(element("div", "empty-symbol", "✳"), element("h3", "", title), element("p", "", message));
  if (actionText) block.append(button(actionText, action));
  $("#results").replaceChildren(block);
  $("#results").setAttribute("aria-busy", "false");
}

function rankingStatus(message = "", error = false) {
  $("#ranking-status").textContent = message;
  $("#ranking-status").classList.toggle("error", error);
}

function renderChips() {
  const chips = $("#skill-chips");
  chips.replaceChildren();
  const icons = ["◇", "✧", "⌘", "◈", "⌕", "◌", "✎"];
  PRESET_SKILLS.forEach((name, index) => {
    const chip = button(name, () => {
      $("#skill-search").value = name;
      refreshRanking();
    }, "chip");
    chip.prepend(element("span", "", icons[index]));
    chip.dataset.skill = name.toLowerCase();
    chips.append(chip);
    const option = element("option"); option.value = name;
    $("#skill-options").append(option);
  });
}

function updateChips(skill) {
  $$(".chip").forEach(chip => {
    const active = chip.dataset.skill === skill;
    chip.classList.toggle("active", active);
    chip.setAttribute("aria-pressed", String(active));
  });
}

async function readPolicy(blockTag) {
  const [clients, tag1, tag2, adapter, version, owner] = await Promise.all([
    state.contract.getTrustedClients({ blockTag }), state.contract.reputationTag1({ blockTag }),
    state.contract.reputationTag2({ blockTag }), state.contract.workHistory({ blockTag }),
    state.contract.policyVersion({ blockTag }), state.contract.owner({ blockTag }),
  ]);
  return { clients, tag1, tag2, adapter, version, owner, blockTag };
}

function renderPolicy(policy) {
  state.policy = policy;
  const details = $("#policy-details");
  details.replaceChildren();
  details.append(element("strong", "", `Published policy · version ${policy.version}`));
  details.append(element("p", "", `Rating metric: ${policy.tag1}${policy.tag2 ? ` / ${policy.tag2}` : ""}. Source: official ERC-8004 Reputation Registry.`));
  details.append(element("p", "", policy.adapter === ZeroAddress ? "History mode: historical rating evidence. No accepted-work ledger is configured." : "History mode: accepted work from the configured ledger adapter."));
  if (policy.adapter !== ZeroAddress) details.append(link(`Work adapter: ${policy.adapter}`, `${CONFIG.explorerUrl}/address/${policy.adapter}`));
  if (!policy.clients.length) details.append(element("p", "", "The owner has not yet configured trusted feedback publishers. Rankings are unavailable until this is published."));
  else {
    details.append(element("p", "", `${policy.clients.length} trusted feedback publisher${policy.clients.length === 1 ? "" : "s"}:`));
    policy.clients.forEach(client => details.append(link(client, `${CONFIG.explorerUrl}/address/${client}`)));
  }
  details.append(link(`Policy owner: ${policy.owner}`, `${CONFIG.explorerUrl}/address/${policy.owner}`));
  $("#admin-panel").hidden = !state.account || state.account.toLowerCase() !== policy.owner.toLowerCase();
  $("#clients-form textarea").value = policy.clients.join("\n");
  $("#metric-form [name=tag1]").value = policy.tag1;
  $("#metric-form [name=tag2]").value = policy.tag2;
  $("#work-form [name=adapter]").value = policy.adapter === ZeroAddress ? "" : policy.adapter;
}

async function connectRead(config) {
  const address = getAddress(config.contractAddress);
  if (address === ZeroAddress) throw new Error("Enter the confirmed AgentSkill deployment address.");
  const url = safeHttpUrl(config.rpcUrl, { allowLocal: true });
  if (!url) throw new Error("Use an HTTPS RPC URL. Localhost HTTP is available for local testing.");
  const request = new FetchRequest(url);
  request.timeout = 15_000;
  const provider = new JsonRpcProvider(request, undefined, { batchMaxCount: 1 });
  try {
    const network = await provider.getNetwork();
    if (network.chainId !== BigInt(CONFIG.chainId)) throw new Error("This deployment uses Ethereum (chain ID 1). Choose an Ethereum RPC.");
    if (await provider.getCode(address) === "0x") throw new Error("No contract exists at this address on Ethereum. Check the confirmed deployment address.");
    const contract = new Contract(address, state.abi, provider);
    const [identity, reputation, reputationWeight, historyWeight, endorsementWeight] = await Promise.all([
      contract.IDENTITY_REGISTRY(), contract.REPUTATION_REGISTRY(), contract.REPUTATION_WEIGHT(),
      contract.HISTORY_WEIGHT(), contract.ENDORSEMENT_WEIGHT(),
    ]);
    if (identity.toLowerCase() !== IDENTITY.toLowerCase() || reputation.toLowerCase() !== REPUTATION.toLowerCase() || reputationWeight !== 6000n || historyWeight !== 2500n || endorsementWeight !== 1500n) {
      throw new Error("This address does not expose the expected AgentSkill registries and score weights.");
    }
    const oldProvider = state.provider;
    state.provider = provider;
    state.contract = contract;
    state.identity = new Contract(IDENTITY, ["function ownerOf(uint256) view returns (address)", "function tokenURI(uint256) view returns (string)"], provider);
    state.config = { ...CONFIG, contractAddress: address, rpcUrl: url };
    state.profileEpoch++;
    if (oldProvider) oldProvider.destroy();
    $("#connection-label").textContent = "Ethereum connected";
    $("#connection-dot").style.background = "#6c9b4f";
    $("#deployment-link").href = `${CONFIG.explorerUrl}/address/${address}`;
    $("#deployment-link").hidden = false;
    const detail = $("#connection-detail");
    detail.replaceChildren(element("p", "", "Ethereum · chain ID 1"), link(address, `${CONFIG.explorerUrl}/address/${address}`));
    await refreshRanking();
  } catch (error) {
    if (provider !== state.provider) provider.destroy();
    throw error;
  }
}

async function refreshRanking() {
  const epoch = ++state.epoch;
  let skill;
  try { skill = normalizeSkill($("#skill-search").value); }
  catch (error) {
    rankingStatus(explainError(error), true);
    emptyResults("Try a skill name.", "Use a short specialty such as Solidity, Research, or Security Audit.");
    return;
  }
  updateChips(skill);
  $("#results-title").textContent = `${titleSkill(skill)} specialists`;
  const url = new URL(location.href); url.searchParams.set("skill", skill); history.replaceState({}, "", url);
  if (!state.contract) {
    rankingStatus();
    $("#results-meta").textContent = "The right experience, all in one place.";
    emptyResults("A clearer view of expertise.", "Connect an AgentSkill deployment to explore real agents, their skills, and the evidence behind every score.", "Set up connection →", openSettings);
    return;
  }
  markLoading();
  rankingStatus("Reading on-chain evidence…");
  $("#results-meta").textContent = "Building a complete ranking at one Ethereum block.";
  try {
    const contract = state.contract;
    const blockTag = await state.provider.getBlockNumber();
    const policy = await readPolicy(blockTag);
    if (epoch !== state.epoch) return;
    renderPolicy(policy);
    if (!policy.clients.length) {
      rankingStatus("Scoring policy is awaiting its trusted feedback publishers.");
      $("#results-meta").textContent = "Skills are open. Rankings await the published trust policy.";
      emptyResults("Good evidence needs a clear source.", "The deployment owner needs to publish trusted feedback clients. Existing reputation will count as soon as that policy is set.", "View connection & policy →", openSettings);
      return;
    }
    const result = await loadLeaderboard(contract, hashId(skill), blockTag, {
      cancelled: () => epoch !== state.epoch,
      onProgress: (done, total) => rankingStatus(`Reading ${done.toLocaleString()} of ${total.toLocaleString()} candidate registrations…`),
    });
    if (!result || epoch !== state.epoch) return;
    rankingStatus();
    $("#results-meta").textContent = result.ranked.length ? `Top ${result.ranked.length} · all ${result.totalCandidates.toLocaleString()} candidate registrations checked` : "No active profiles for this specialty yet.";
    $("#snapshot-label").textContent = `Ethereum · block ${blockTag.toLocaleString()} · policy ${policy.version}`;
    if (!result.ranked.length) {
      emptyResults("Be the first in your specialty.", `No agent currently advertises ${titleSkill(skill)} here. Add it to your profile and bring your existing reputation with you.`, "Add your skill →", openManage);
      return;
    }
    renderRankings(result.ranked, skill);
  } catch (error) {
    if (epoch !== state.epoch) return;
    rankingStatus(explainError(error), true);
    $("#results-meta").textContent = "A complete ranking could not be read.";
    $("#snapshot-label").textContent = "No incomplete ranking is being displayed.";
    emptyResults("Let’s reconnect to the evidence.", "One of the chain reads was interrupted. Refresh to try again, or check your connection settings.", "Try again →", refreshRanking);
  } finally {
    if (epoch === state.epoch) $("#results").setAttribute("aria-busy", "false");
  }
}

function renderRankings(ranked, skill) {
  const nodes = ranked.map((agent, index) => {
    const row = element("article", "agent-row");
    row.append(element("span", "agent-rank", String(index + 1).padStart(2, "0")), element("div", "avatar", ["✳", "◈", "✧", "⌘"][Number(agent.agentId % 4n)]));
    const info = element("div");
    info.append(button(`Agent #${agent.agentId}`, () => openProfile(agent.agentId), "agent-name"));
    const meta = element("div", "agent-meta");
    meta.append(element("span", "", `${agent.score.feedbackCount} ratings`), element("span", "", "·"), element("span", "", `${agent.score.endorsements} endorsements`));
    info.append(meta);
    const score = element("div", "agent-score");
    score.append(element("strong", "", formatScore(agent.score.total)), element("small", "", " / 100"), element("span", "", "weighted score"));
    const bar = element("div", "mini-bar");
    [["reputation", agent.score.reputationPoints], ["history", agent.score.historyPoints], ["endorsements", agent.score.endorsementPoints]].forEach(([name, points]) => {
      const part = element("i", name); part.style.width = `${Number(points) / 100}%`; bar.append(part);
    });
    score.append(bar);
    row.append(info, score, button(`View ${titleSkill(skill)} evidence →`, () => openProfile(agent.agentId), "text-button profile-open"));
    return row;
  });
  $("#results").replaceChildren(...nodes);
}

async function connectWallet() {
  if (!window.ethereum?.request) throw new Error("Open AgentSkill in a browser with an Ethereum wallet installed. Browsing works without a wallet.");
  await window.ethereum.request({ method: "eth_requestAccounts" });
  const wallet = new BrowserProvider(window.ethereum, "any");
  const signer = await wallet.getSigner();
  state.wallet = wallet;
  state.account = await signer.getAddress();
  $("#connect-wallet").textContent = shortAddress(state.account);
  if (state.policy) renderPolicy(state.policy);
  return signer;
}

async function writeContract() {
  requireDeployment();
  if (!state.wallet || !state.account) await connectWallet();
  const chain = await window.ethereum.request({ method: "eth_chainId" });
  if (BigInt(chain) !== BigInt(CONFIG.chainId)) {
    await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x1" }] });
    const switched = await window.ethereum.request({ method: "eth_chainId" });
    if (BigInt(switched) !== 1n) throw new Error("Switch your wallet to Ethereum before continuing.");
  }
  state.wallet = new BrowserProvider(window.ethereum, "any");
  const signer = await state.wallet.getSigner();
  state.account = await signer.getAddress();
  $("#connect-wallet").textContent = shortAddress(state.account);
  return new Contract(state.config.contractAddress, state.abi, signer);
}

async function transact(method, args, successMessage) {
  if (state.busy) throw new Error("Another wallet request is still in progress. Wait for its result first.");
  state.busy = true;
  $$("button[type=submit]").forEach(node => { node.disabled = true; });
  let hash;
  try {
    const writer = await writeContract();
    // Simulate with the current signer to surface owner/duplicate errors before asking for a transaction.
    await writer[method].staticCall(...args);
    toast("Review the transaction in your wallet. AgentSkill charges no application fee.");
    const tx = await writer[method](...args);
    hash = tx.hash;
    toast("Transaction submitted. Waiting for an Ethereum confirmation…", { hash });
    let receipt;
    try { receipt = await tx.wait(1, 180_000); }
    catch (error) {
      if (error.code === "TRANSACTION_REPLACED" && !error.cancelled && error.receipt?.status === 1) {
        receipt = error.receipt; hash = receipt.hash;
      } else throw error;
    }
    if (!receipt || receipt.status !== 1) throw new Error("The transaction did not succeed. Check the transaction before trying again.");
    toast(successMessage, { hash });
    await refreshRanking();
    return receipt;
  } catch (error) {
    const message = error.code === "TIMEOUT" && hash ? "Still waiting for confirmation. Track this transaction before submitting again." : explainError(error);
    toast(message, { error: true, hash });
    throw new Error(message);
  } finally {
    state.busy = false;
    $$("button[type=submit]").forEach(node => { node.disabled = false; });
  }
}

function openSettings() {
  $("#contract-address").value = state.config.contractAddress || "";
  $("#rpc-url").value = state.config.rpcUrl || CONFIG.rpcUrl;
  $("#settings-error").textContent = "";
  showDialog("#settings-dialog");
}

function openManage() {
  $("#register-error").textContent = "";
  $("#register-agent-id").value = store.read("agentId") || "";
  $("#register-form [name=skill]").value = $("#skill-search").value;
  showDialog("#manage-dialog");
}

function openEndorsement(agentId, skill) {
  state.endorsement = { agentId, skill };
  $("#endorse-summary").textContent = `You’re endorsing Agent #${agentId} for ${titleSkill(skill.name)}.`;
  $("#endorser-id").value = store.read("agentId") || "";
  $("#endorse-error").textContent = "";
  showDialog("#endorse-dialog");
}

async function openProfile(rawId) {
  const request = ++state.profileEpoch;
  try {
    requireDeployment();
    const agentId = parseAgentId(rawId);
    state.profileId = agentId;
    showDialog("#profile-dialog");
    $("#profile-content").replaceChildren(element("p", "muted", "Reading this identity and its evidence…"));
    const blockTag = await state.provider.getBlockNumber();
    const [owner, skills, uriResult] = await Promise.all([
      state.identity.ownerOf(agentId, { blockTag }), state.contract.getAgentSkills(agentId, { blockTag }),
      state.identity.tokenURI(agentId, { blockTag }).catch(() => ""),
    ]);
    if (request !== state.profileEpoch) return;
    const content = $("#profile-content");
    content.replaceChildren();
    const heading = element("div", "profile-title");
    const headingText = element("div");
    headingText.append(element("h2", "", `Agent #${agentId}`), element("p", "", "Registered Ethereum · ERC-8004 identity"));
    heading.append(element("div", "avatar", "✳"), headingText);
    content.append(heading);
    const links = element("div", "profile-links");
    links.append(link(`Owner ${shortAddress(owner)} ↗`, `${CONFIG.explorerUrl}/address/${owner}`), link("Identity on Etherscan ↗", `${CONFIG.explorerUrl}/nft/${IDENTITY}/${agentId}`));
    const registrationUrl = safeHttpUrl(uriResult);
    if (registrationUrl) links.append(link("Registration document ↗", registrationUrl));
    content.append(links);
    if (uriResult.startsWith("ipfs://")) content.append(element("p", "form-hint", `Registration document: ${uriResult.slice(0, 200)}`));
    if (!skills.length) content.append(element("div", "soft-note", "This identity has not added any active skills yet."));
    const scores = await Promise.allSettled(skills.map(skill => state.contract.getScoreBreakdown(agentId, skill.id, { blockTag })));
    if (request !== state.profileEpoch) return;
    skills.forEach((skill, index) => {
      const card = element("section", "profile-skill");
      const top = element("div", "profile-skill-heading");
      top.append(element("h3", "", titleSkill(skill.name)));
      if (scores[index].status === "fulfilled") {
        const score = scores[index].value;
        top.append(element("strong", "", `${formatScore(score.total)} / 100`));
        card.append(top);
        [["Existing reputation · 60%", score.reputationPoints], ["Historical evidence · 25%", score.historyPoints], ["Skill endorsements · 15%", score.endorsementPoints]].forEach(([label, points]) => {
          const line = element("div", "breakdown-line");
          line.append(element("span", "", label), element("span", "", `${formatScore(points)} pts`));
          card.append(line);
        });
        const history = score.historySource === 1n ? `${score.acceptedWork} accepted / ${score.completedWork} finalized jobs.` : "History uses rating depth; no accepted-work ledger is configured.";
        card.append(element("p", "form-hint", `${formatScore(score.reputationBps)} / 100 reputation across ${score.feedbackCount} feedback records. ${history} ${score.endorsements} skill endorsements.`));
        card.append(element("span", "source-badge", score.historySource === 1n ? "Accepted-work ledger connected" : "Historical feedback evidence"));
      } else {
        top.append(element("strong", "", "—"));
        card.append(top, element("p", "form-hint", explainError(scores[index].reason)), element("p", "form-hint", `${skill.endorsements} skill endorsements recorded.`));
      }
      const actions = element("div", "skill-actions");
      if (state.account?.toLowerCase() === owner.toLowerCase()) {
        actions.append(button("Hide this skill", async () => {
          try { await transact("hideSkill", [agentId, skill.id], "Skill hidden. You can reactivate it by adding the same name."); await openProfile(agentId); }
          catch { /* Transaction state is shown in the persistent toast. */ }
        }, "text-button danger-button"));
      } else actions.append(button("Endorse this skill ✧", () => openEndorsement(agentId, skill), "text-button"));
      actions.append(button("Find specialists →", () => {
        closeDialog($("#profile-dialog")); $("#skill-search").value = titleSkill(skill.name); refreshRanking();
      }, "text-button"));
      card.append(actions);
      content.append(card);
    });
    if (state.account?.toLowerCase() === owner.toLowerCase()) content.append(button("Add another skill ↗", () => {
      store.write("agentId", String(agentId)); openManage();
    }, "text-button manage-view"));
    content.append(element("p", "profile-note", `Evidence snapshot: Ethereum block ${blockTag.toLocaleString()}. Skill registration is self-declared; reputation is shared across skills.`));
  } catch (error) {
    if (request !== state.profileEpoch) return;
    if ($("#profile-dialog").open) $("#profile-content").replaceChildren(element("div", "soft-note", explainError(error)));
    else toast(explainError(error), { error: true });
  }
}

function installEvents() {
  $$("[data-close]").forEach(node => node.addEventListener("click", () => closeDialog(node.closest("dialog"))));
  $$("dialog").forEach(dialog => {
    dialog.addEventListener("close", placeToast);
    dialog.addEventListener("click", event => {
      if (event.target === dialog) {
        const r = dialog.getBoundingClientRect();
        if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) closeDialog(dialog);
      }
    });
  });
  $("#toast-close").addEventListener("click", () => { $("#toast").hidden = true; });
  $$("[data-action]").forEach(node => node.addEventListener("click", async () => {
    try {
      const action = node.dataset.action;
      if (action === "settings") openSettings();
      else if (action === "explain") showDialog("#explain-dialog");
      else if (action === "manage") openManage();
      else if (action === "refresh") await refreshRanking();
      else if (action === "connect") await connectWallet();
      else if (action === "view-own") await openProfile($("#register-agent-id").value);
      else if (action === "clear-work") await transact("clearWorkHistory", [], "Historical feedback mode is now active.");
    } catch (error) { toast(explainError(error), { error: true }); }
  }));
  $("#search-form").addEventListener("submit", event => { event.preventDefault(); refreshRanking(); });
  $("#profile-search").addEventListener("submit", event => { event.preventDefault(); openProfile($("#profile-id").value); });
  $("#settings-form").addEventListener("submit", async event => {
    event.preventDefault();
    if (state.busy) return;
    const submit = event.submitter || event.currentTarget.querySelector("button[type=submit]"); submit.disabled = true;
    $("#settings-error").textContent = "";
    try {
      await connectRead({ contractAddress: $("#contract-address").value.trim(), rpcUrl: $("#rpc-url").value.trim() });
      store.write("connection", { contractAddress: state.config.contractAddress, rpcUrl: state.config.rpcUrl });
      closeDialog($("#settings-dialog"));
    } catch (error) { $("#settings-error").textContent = explainError(error); }
    finally { submit.disabled = false; }
  });
  $("#register-form").addEventListener("submit", async event => {
    event.preventDefault(); $("#register-error").textContent = "";
    try {
      const data = new FormData(event.currentTarget);
      const agentId = parseAgentId(data.get("agentId"));
      const skill = normalizeSkill(data.get("skill"));
      await transact("registerSkill", [agentId, skill], "Skill added. Your existing reputation is already part of the score.");
      store.write("agentId", String(agentId));
      closeDialog($("#manage-dialog"));
      $("#skill-search").value = titleSkill(skill); await refreshRanking();
      await openProfile(agentId);
    } catch (error) { $("#register-error").textContent = explainError(error); }
  });
  $("#endorse-form").addEventListener("submit", async event => {
    event.preventDefault(); $("#endorse-error").textContent = "";
    try {
      const id = parseAgentId($("#endorser-id").value);
      const target = state.endorsement;
      await transact("endorseSkill", [id, target.agentId, target.skill.id], "Endorsement recorded. A little recognition, on the record.");
      store.write("agentId", String(id));
      closeDialog($("#endorse-dialog"));
      await openProfile(target.agentId);
    } catch (error) { $("#endorse-error").textContent = explainError(error); }
  });
  $("#clients-form").addEventListener("submit", async event => {
    event.preventDefault();
    try {
      const clients = $("#clients-form textarea").value.split(/[\s,]+/).filter(Boolean).map(getAddress);
      if (!clients.length || clients.length > 32 || new Set(clients).size !== clients.length || clients.includes(ZeroAddress)) throw new Error("Enter 1–32 distinct, nonzero feedback publisher addresses.");
      await transact("setTrustedClients", [clients], "Trusted feedback publishers updated.");
    } catch (error) { toast(explainError(error), { error: true }); }
  });
  $("#metric-form").addEventListener("submit", async event => {
    event.preventDefault();
    try { await transact("setReputationMetric", [$("#metric-form [name=tag1]").value, $("#metric-form [name=tag2]").value], "Reputation metric updated."); }
    catch (error) { toast(explainError(error), { error: true }); }
  });
  $("#work-form").addEventListener("submit", async event => {
    event.preventDefault();
    try { await transact("setWorkHistory", [getAddress($("#work-form [name=adapter]").value.trim())], "Accepted-work ledger connected."); }
    catch (error) { toast(explainError(error), { error: true }); }
  });
  if (window.ethereum?.on) {
    const resetWallet = () => {
      state.account = null; state.wallet = null;
      $("#connect-wallet").textContent = "Connect wallet ↗";
      $("#admin-panel").hidden = true;
      if ($("#profile-dialog").open && state.profileId !== null) openProfile(state.profileId);
    };
    window.ethereum.on("accountsChanged", resetWallet);
    window.ethereum.on("chainChanged", resetWallet);
  }
}

async function start() {
  renderChips();
  installEvents();
  const params = new URLSearchParams(location.search);
  if (params.has("skill")) $("#skill-search").value = params.get("skill").slice(0, 48);
  const response = await fetch("./AgentSkill.abi.json");
  if (!response.ok) throw new Error("The local contract ABI could not be loaded. Serve the complete web folder over HTTP.");
  state.abi = await response.json();
  try { updateChips(normalizeSkill($("#skill-search").value)); }
  catch { $("#skill-search").value = "Solidity"; updateChips("solidity"); }
  if (state.config.contractAddress) {
    try {
      await connectRead(state.config);
      if (params.has("agent")) await openProfile(params.get("agent"));
    } catch (error) { rankingStatus(explainError(error), true); }
  }
}

start().catch(error => toast(explainError(error), { error: true }));
