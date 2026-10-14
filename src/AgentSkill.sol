// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";
import {IAgentWorkHistory} from "./interfaces/IAgentWorkHistory.sol";

/// @title AgentSkill — discover agents through skills and existing evidence
/// @notice Ethereum ERC-8004 identities register their skills and endorse other identities.
/// @dev No custody, token, proxy, payable entrypoint, or external state-changing call.
/// Scores are live reads, not reset on enrollment. All score components are basis points (0..10,000).
/// Trust model: the owner never writes a score, but the owner-selected feedback publishers (and the
/// optional work adapter) author the reputation and history components, 85% of every score. Anyone
/// may publish feedback in the official registry; only records from the trusted set are read.
contract AgentSkill is Ownable2Step {
    /// @notice Official Ethereum ERC-8004 IdentityRegistry; agent IDs are scoped to this registry.
    IIdentityRegistry public constant IDENTITY_REGISTRY =
        IIdentityRegistry(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
    /// @notice Official Ethereum ERC-8004 ReputationRegistry; queried for every score read.
    IReputationRegistry public constant REPUTATION_REGISTRY =
        IReputationRegistry(0x8004BAa17C55a88189AE136b182e5fdA19dE9b63);
    /// @notice Full scale for normalized metrics.
    uint256 public constant BPS = 10_000;
    /// @notice Weight of an existing reputation rating, in basis points.
    uint256 public constant REPUTATION_WEIGHT = 6_000;
    /// @notice Weight of historical evidence, in basis points.
    uint256 public constant HISTORY_WEIGHT = 2_500;
    /// @notice Weight of skill-specific endorsements, in basis points.
    uint256 public constant ENDORSEMENT_WEIGHT = 1_500;
    /// @notice Endorsements needed to reach the endorsement component's ceiling.
    uint256 public constant ENDORSEMENT_CAP = 20;
    /// @notice Finalized work outcomes (or feedback records in fallback mode) for full confidence.
    uint256 public constant HISTORY_CONFIDENCE_CAP = 20;
    /// @notice Maximum concurrently active skills per agent; hidden skills release their slot.
    uint256 public constant MAX_AGENT_SKILLS = 32;
    /// @notice Maximum skill label length in ASCII bytes before normalization.
    uint256 public constant MAX_SKILL_LENGTH = 48;
    /// @notice Maximum trusted feedback publishers.
    uint256 public constant MAX_CLIENTS = 32;
    /// @notice Maximum candidates scanned in one ranking page.
    uint256 public constant MAX_SCAN = 50;
    /// @notice Maximum ranked results returned in one page.
    uint256 public constant MAX_RESULTS = 20;
    /// @notice Gas cap for the cheap existence reads (ownerOf, registry handshakes).
    uint256 public constant SOURCE_GAS_LIMIT = 2_000_000;
    /// @notice Smallest owner-settable per-source gas budget for a summary read.
    uint256 public constant MIN_SOURCE_GAS_BUDGET = 1_000_000;
    /// @notice Largest owner-settable per-source gas budget; keep page size × budget under the RPC call cap.
    uint256 public constant MAX_SOURCE_GAS_BUDGET = 10_000_000;
    /// @notice Default per-source gas budget: roughly 650 stored records per agent in the official registry.
    uint256 public constant DEFAULT_SOURCE_GAS_BUDGET = 5_000_000;
    /// @notice Gas kept for decoding and arithmetic after a budgeted source read.
    uint256 public constant CALL_GAS_RESERVE = 60_000;

    /// @notice Canonical skill label and its historical, unique endorsement count.
    struct Skill {
        bytes32 id;
        string name;
        uint256 endorsements;
    }

    /// @notice Auditable live score; all points and normalized metrics are on a 10,000 point scale.
    /// @dev historySource: 0 = historical rating evidence, 1 = configured accepted-work ledger.
    /// feedbackCount is never described as a job count. Policy version identifies the scoring configuration.
    struct ScoreBreakdown {
        uint256 total;
        uint256 reputationPoints;
        uint256 historyPoints;
        uint256 endorsementPoints;
        uint256 reputationBps;
        uint256 historyBps;
        uint256 endorsements;
        uint64 feedbackCount;
        int128 reputationValue;
        uint8 reputationDecimals;
        uint64 completedWork;
        uint64 acceptedWork;
        uint8 historySource;
        uint64 policyVersion;
    }

    /// @notice One ranked candidate with enough information to display an evidence breakdown.
    /// @dev When unavailable is true the score is unset (never a fabricated zero) and unavailableSource
    /// names the registry or adapter that failed, exceeded its gas budget, or returned invalid data.
    struct RankedAgent {
        uint256 agentId;
        ScoreBreakdown score;
        bool unavailable;
        address unavailableSource;
    }

    struct SkillState {
        bool known;
        bool active;
        uint32 position;
        uint256 endorsements;
    }

    /// @notice Optional authoritative work ledger adapter; unset means historical-feedback mode.
    IAgentWorkHistory public workHistory;
    /// @notice Primary metric tag filter. Empty (the default) matches every record of the trusted publishers.
    string public reputationTag1;
    /// @notice Optional secondary metric filter; empty means all secondary tags within the primary filter.
    string public reputationTag2;
    /// @notice Gas forwarded to each summary read (reputation registry and work adapter), per candidate.
    uint256 public sourceGasBudget = DEFAULT_SOURCE_GAS_BUDGET;
    /// @notice Incremented on every scoring-policy change for reproducible client snapshots.
    uint64 public policyVersion;

    address[] private _trustedClients;
    mapping(uint256 => bytes32[]) private _agentSkills;
    mapping(uint256 => mapping(bytes32 => SkillState)) private _skills;
    mapping(bytes32 => string) private _skillNames;
    mapping(bytes32 => uint256[]) private _skillAgents;
    bytes32[] private _catalog;

    /// @notice Whether this identity has ever endorsed the target's skill (persists through transfers).
    mapping(uint256 => mapping(bytes32 => mapping(uint256 => bool))) public hasEndorsed;
    /// @notice Whether this controlling wallet has endorsed the target's skill through any identity.
    mapping(uint256 => mapping(bytes32 => mapping(address => bool))) public hasWalletEndorsed;

    /// @notice Emitted when a skill is first added or reactivated.
    event SkillRegistered(uint256 indexed agentId, bytes32 indexed skillId, string name);
    /// @notice Emitted when a skill is hidden; endorsements and catalog membership are retained.
    event SkillHidden(uint256 indexed agentId, bytes32 indexed skillId);
    /// @notice Emitted for a unique endorsement by an identity and its controlling wallet.
    event SkillEndorsed(
        uint256 indexed agentId, bytes32 indexed skillId, uint256 indexed endorserId, address wallet
    );
    /// @notice Publishes the complete reviewer trust policy.
    event TrustedClientsChanged(address[] clients, uint64 version);
    /// @notice Publishes the metric filters used to read reputation.
    event ReputationMetricChanged(string tag1, string tag2, uint64 version);
    /// @notice Publishes the work ledger adapter, or the absence of one when cleared.
    event WorkHistoryChanged(address indexed adapter, uint64 version);
    /// @notice Publishes the per-source gas budget used for every summary read.
    event SourceGasBudgetChanged(uint256 budget, uint64 version);

    /// @notice The ID does not resolve to an owner in the official registry.
    error UnregisteredAgent(uint256 agentId);
    /// @notice The caller does not currently own this agent identity.
    error NotAgentOwner(uint256 agentId);
    /// @notice A required registry is missing or did not answer a required read.
    error RegistryUnavailable(address registry);
    /// @notice A skill label is empty, too long, or contains unsupported characters.
    error InvalidSkill();
    /// @notice The agent already advertises this skill.
    error SkillAlreadyActive();
    /// @notice The agent does not currently advertise this skill.
    error SkillNotActive();
    /// @notice The agent has exhausted its distinct-skill capacity.
    error SkillLimitReached();
    /// @notice Endorsements of oneself or another identity under the same owner are forbidden.
    error SelfEndorsement();
    /// @notice This identity or wallet has already endorsed this agent-skill pair.
    error DuplicateEndorsement();
    /// @notice Score queries require an explicitly configured, nonempty publisher trust set.
    error RankingNotConfigured();
    /// @notice A policy contains invalid or duplicate addresses, an invalid metric, or wrong namespace.
    error InvalidPolicy();
    /// @notice A ranking source failed, exceeded its gas cap, or returned invalid data.
    error ScoreSourceUnavailable(address source, uint256 agentId);
    /// @notice A pagination parameter is outside the bounded range.
    error InvalidPage();
    /// @notice The call carries less gas than one budgeted source read needs; raise the call gas or lower the budget.
    error InsufficientCallGas(uint256 required);
    /// @notice Renouncing administration would prevent maintaining external-source policy.
    error OwnershipRequired();

    /// @notice Deploys a non-upgradeable AgentSkill instance with explicit launch ownership.
    /// @param initialOwner Launch owner's address; never inferred from factory or transaction sender.
    /// @dev Constructor performs no external calls, allowing deployment on an empty chain.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Publishes the feedback clients whose existing records contribute to all rankings.
    /// @param clients Nonzero, distinct publisher addresses, 1..32 entries; obtain from actual IMD records.
    /// @dev Order does not affect scoring. Changing this trust policy can change every agent's ranking.
    function setTrustedClients(address[] calldata clients) external onlyOwner {
        if (clients.length == 0 || clients.length > MAX_CLIENTS) revert InvalidPolicy();
        for (uint256 i; i < clients.length; ++i) {
            if (clients[i] == address(0)) revert InvalidPolicy();
            for (uint256 j; j < i; ++j) {
                if (clients[i] == clients[j]) revert InvalidPolicy();
            }
        }
        _trustedClients = clients;
        emit TrustedClientsChanged(clients, ++policyVersion);
    }

    /// @notice Selects which records of the trusted publishers count as the 0..100 quality rating.
    /// @param tag1 Primary metric filter, at most 48 bytes. Empty matches every record (the registry's
    /// match-all filter), which is the default so no publisher tag is silently dropped.
    /// @param tag2 Optional secondary metric filter, at most 48 bytes; empty matches every secondary tag.
    /// @dev Narrow to one tag when a trusted publisher also records non-percentage metrics (latency,
    /// revenue, binary outcomes); the registry has no multi-tag filter, so a tag list cannot be expressed.
    function setReputationMetric(string calldata tag1, string calldata tag2) external onlyOwner {
        if (bytes(tag1).length > MAX_SKILL_LENGTH || bytes(tag2).length > MAX_SKILL_LENGTH) {
            revert InvalidPolicy();
        }
        reputationTag1 = tag1;
        reputationTag2 = tag2;
        emit ReputationMetricChanged(tag1, tag2, ++policyVersion);
    }

    /// @notice Sets the gas forwarded to each summary read; a source that needs more is reported unavailable.
    /// @param budget Gas per read, between MIN_SOURCE_GAS_BUDGET and MAX_SOURCE_GAS_BUDGET.
    /// @dev The official getSummary scans every stored record of every listed client (about 7,600 gas each),
    /// so the budget bounds the history size that can be scored. Each getTopAgents page may spend up to
    /// scanLimit × budget per configured source; keep that under the RPC's eth_call gas cap.
    function setSourceGasBudget(uint256 budget) external onlyOwner {
        if (budget < MIN_SOURCE_GAS_BUDGET || budget > MAX_SOURCE_GAS_BUDGET) revert InvalidPolicy();
        sourceGasBudget = budget;
        emit SourceGasBudgetChanged(budget, ++policyVersion);
    }

    /// @notice Configures an audited adapter over the actual IMD accepted-work ledger.
    /// @param adapter Deployed IAgentWorkHistory implementation for the official identity namespace.
    /// @dev The task supplies no IMD work-ledger address. This setting is optional, explicit, and observable.
    function setWorkHistory(address adapter) external onlyOwner {
        if (adapter.code.length == 0) revert InvalidPolicy();
        try IAgentWorkHistory(adapter).identityRegistry{gas: SOURCE_GAS_LIMIT}() returns (address registry) {
            if (registry != address(IDENTITY_REGISTRY)) revert InvalidPolicy();
        } catch {
            revert InvalidPolicy();
        }
        workHistory = IAgentWorkHistory(adapter);
        emit WorkHistoryChanged(adapter, ++policyVersion);
    }

    /// @notice Returns to historical-feedback mode if the optional work ledger is unavailable or retired.
    function clearWorkHistory() external onlyOwner {
        delete workHistory;
        emit WorkHistoryChanged(address(0), ++policyVersion);
    }

    /// @notice Returns the complete publisher trust set; empty means rankings are not configured.
    /// @return clients Addresses used for every reputation summary.
    function getTrustedClients() external view returns (address[] memory clients) {
        return _trustedClients;
    }

    /// @notice Disallows irreversible loss of scoring-policy maintenance; use two-step ownership transfer.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }

    /// @notice Advertises or reactivates a skill for an identity owned by the caller.
    /// @param agentId Registered ERC-8004 token ID; only its current owner may call.
    /// @param name Human-readable ASCII skill name, canonicalized to lowercase and single spaces.
    /// @return skillId Hash of the canonical skill name.
    /// @dev The cap counts active skills only. A skill ever registered stays a ranking candidate once,
    /// so reactivation never pushes the agent into the candidate list twice.
    function registerSkill(uint256 agentId, string calldata name) external returns (bytes32 skillId) {
        _requireOwner(agentId);
        string memory canonical;
        (skillId, canonical) = normalizeSkill(name);
        SkillState storage state = _skills[agentId][skillId];
        if (state.active) revert SkillAlreadyActive();
        bytes32[] storage active = _agentSkills[agentId];
        if (active.length >= MAX_AGENT_SKILLS) revert SkillLimitReached();
        if (!state.known) {
            state.known = true;
            _skillAgents[skillId].push(agentId);
            if (bytes(_skillNames[skillId]).length == 0) {
                _skillNames[skillId] = canonical;
                _catalog.push(skillId);
            }
        }
        state.active = true;
        state.position = uint32(active.length);
        active.push(skillId);
        emit SkillRegistered(agentId, skillId, canonical);
    }

    /// @notice Hides a skill from discovery, releasing its slot without resetting endorsements.
    /// @param agentId Identity owned by the caller.
    /// @param skillId Canonical skill hash.
    /// @dev Swap-and-pop removal: the agent's last active skill takes the hidden skill's place.
    function hideSkill(uint256 agentId, bytes32 skillId) external {
        _requireOwner(agentId);
        SkillState storage state = _skills[agentId][skillId];
        if (!state.active) revert SkillNotActive();
        bytes32[] storage active = _agentSkills[agentId];
        uint256 last = active.length - 1;
        if (state.position != last) {
            bytes32 moved = active[last];
            active[state.position] = moved;
            _skills[agentId][moved].position = state.position;
        }
        active.pop();
        state.active = false;
        state.position = 0;
        emit SkillHidden(agentId, skillId);
    }

    /// @notice Permanently records one endorsement from a registered agent for an active skill.
    /// @param endorserId Registered identity currently owned by the caller.
    /// @param agentId Other registered agent whose skill is endorsed.
    /// @param skillId Canonical skill hash.
    /// @dev One vote per endorser ID AND controlling wallet per pair. Multiple wallets remain a Sybil risk.
    function endorseSkill(uint256 endorserId, uint256 agentId, bytes32 skillId) external {
        _requireOwner(endorserId);
        address targetOwner = _agentOwner(agentId);
        if (endorserId == agentId || targetOwner == msg.sender) revert SelfEndorsement();
        SkillState storage state = _skills[agentId][skillId];
        if (!state.active) revert SkillNotActive();
        if (hasEndorsed[agentId][skillId][endorserId] || hasWalletEndorsed[agentId][skillId][msg.sender]) {
            revert DuplicateEndorsement();
        }
        hasEndorsed[agentId][skillId][endorserId] = true;
        hasWalletEndorsed[agentId][skillId][msg.sender] = true;
        ++state.endorsements;
        emit SkillEndorsed(agentId, skillId, endorserId, msg.sender);
    }

    /// @notice Returns all active skills of an agent, bounded by MAX_AGENT_SKILLS.
    /// @param agentId Registered agent token ID.
    /// @return skills Canonical names, hashes, and unique endorsement counts; hiding a skill may reorder the list.
    function getAgentSkills(uint256 agentId) external view returns (Skill[] memory skills) {
        _agentOwner(agentId);
        bytes32[] storage ids = _agentSkills[agentId];
        skills = new Skill[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            bytes32 id = ids[i];
            skills[i] = Skill(id, _skillNames[id], _skills[agentId][id].endorsements);
        }
    }

    /// @notice Returns a bounded page of the permanent skill catalog, including currently hidden entries.
    /// @param offset Starting catalog index.
    /// @param limit Maximum entries, 1..50.
    /// @return skills Names and IDs; endorsements is zero because it is specific to agent-skill pairs.
    /// @return total Total catalog length.
    function getSkills(uint256 offset, uint256 limit)
        external
        view
        returns (Skill[] memory skills, uint256 total)
    {
        total = _catalog.length;
        uint256 end = _pageEnd(offset, limit, total);
        skills = new Skill[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            bytes32 id = _catalog[i];
            skills[i - offset] = Skill(id, _skillNames[id], 0);
        }
    }

    /// @notice Returns the number of agents ever advertising a skill, including hidden registrations.
    /// @param skillId Canonical skill hash.
    /// @return count Candidate count for pagination, not necessarily the active-agent count.
    function skillAgentCount(bytes32 skillId) external view returns (uint256 count) {
        return _skillAgents[skillId].length;
    }

    /// @notice Gets a fresh weighted score, incorporating reputation that predates AgentSkill registration.
    /// @param agentId Registered identity advertising the skill.
    /// @param skillId Canonical skill hash.
    /// @return score Raw evidence and weighted points; unavailable sources revert rather than fabricating zeros.
    function getScoreBreakdown(uint256 agentId, bytes32 skillId)
        public
        view
        returns (ScoreBreakdown memory score)
    {
        _agentOwner(agentId);
        if (!_skills[agentId][skillId].active) revert SkillNotActive();
        if (_trustedClients.length == 0) revert RankingNotConfigured();
        _checkReputationRegistry();
        return _score(agentId, skillId);
    }

    /// @notice Returns the highest scoring agents within a bounded candidate page, descending by score.
    /// @param skillId Canonical skill hash.
    /// @param offset Candidate offset from the previous call's nextOffset; zero starts a search.
    /// @param scanLimit Candidates to examine, 1..50. Hidden skills are skipped but advance the cursor.
    /// @param resultLimit Results to retain, 1..20, no greater than scanLimit.
    /// @return ranked Top scored candidates within this page (ties use lower agent ID first), followed by
    /// every scanned candidate whose evidence could not be read, flagged `unavailable` with its source.
    /// @return nextOffset Cursor for the next page. It is below offset + scanLimit when the call ran out of
    /// gas for another budgeted source read; continue from it with the same block to finish the scan.
    /// @return totalCandidates All historical candidates, including hidden registrations.
    /// @dev For GLOBAL top K, merge every page's top K at the SAME block. No cap on total registrations.
    /// One unscorable agent never hides the others, and its absence is reported rather than scored as zero.
    function getTopAgents(bytes32 skillId, uint256 offset, uint256 scanLimit, uint256 resultLimit)
        external
        view
        returns (RankedAgent[] memory ranked, uint256 nextOffset, uint256 totalCandidates)
    {
        if (resultLimit == 0 || resultLimit > MAX_RESULTS || resultLimit > scanLimit) {
            revert InvalidPage();
        }
        if (_trustedClients.length == 0) revert RankingNotConfigured();
        _checkReputationRegistry();
        totalCandidates = _skillAgents[skillId].length;
        nextOffset = _pageEnd(offset, scanLimit, totalCandidates);
        (ranked, nextOffset) = _scanPage(skillId, offset, nextOffset, resultLimit);
    }

    /// @notice Canonicalizes ASCII labels so spacing and letter case cannot split a leaderboard.
    /// @param name 1..48 input bytes; letters, digits, spaces and + # . / - are supported.
    /// @return skillId keccak256 of the canonical label.
    /// @return canonical Lowercase, trimmed label with single interior spaces and at least one letter or digit.
    function normalizeSkill(string memory name)
        public
        pure
        returns (bytes32 skillId, string memory canonical)
    {
        bytes memory input = bytes(name);
        if (input.length == 0 || input.length > MAX_SKILL_LENGTH) revert InvalidSkill();
        bytes memory output = new bytes(input.length);
        uint256 length;
        bool pendingSpace;
        bool hasAlphanumeric;
        for (uint256 i; i < input.length; ++i) {
            uint8 c = uint8(input[i]);
            if (c == 32) {
                if (length != 0) pendingSpace = true;
                continue;
            }
            if (c >= 65 && c <= 90) c += 32;
            bool alphanumeric = (c >= 97 && c <= 122) || (c >= 48 && c <= 57);
            if (!alphanumeric && c != 43 && c != 35 && c != 46 && c != 47 && c != 45) revert InvalidSkill();
            if (alphanumeric) hasAlphanumeric = true;
            if (pendingSpace) output[length++] = bytes1(uint8(32));
            pendingSpace = false;
            output[length++] = bytes1(c);
        }
        if (!hasAlphanumeric) revert InvalidSkill();
        assembly ("memory-safe") {
            mstore(output, length)
        }
        canonical = string(output);
        skillId = keccak256(output);
    }

    /// @dev Live reads only: mutations perform registry STATICCALLs before updating local storage.
    function _requireOwner(uint256 agentId) private view {
        if (_agentOwner(agentId) != msg.sender) revert NotAgentOwner(agentId);
    }

    function _agentOwner(uint256 agentId) private view returns (address ownerAddress) {
        if (address(IDENTITY_REGISTRY).code.length == 0) {
            revert RegistryUnavailable(address(IDENTITY_REGISTRY));
        }
        try IDENTITY_REGISTRY.ownerOf{gas: SOURCE_GAS_LIMIT}(agentId) returns (address currentOwner) {
            if (currentOwner == address(0)) revert UnregisteredAgent(agentId);
            return currentOwner;
        } catch {
            revert UnregisteredAgent(agentId);
        }
    }

    function _checkReputationRegistry() private view {
        if (address(REPUTATION_REGISTRY).code.length == 0) {
            revert RegistryUnavailable(address(REPUTATION_REGISTRY));
        }
        try REPUTATION_REGISTRY.getIdentityRegistry{gas: SOURCE_GAS_LIMIT}() returns (address registry) {
            if (registry != address(IDENTITY_REGISTRY)) {
                revert RegistryUnavailable(address(REPUTATION_REGISTRY));
            }
        } catch {
            revert RegistryUnavailable(address(REPUTATION_REGISTRY));
        }
    }

    /// @dev Scores candidates [offset, end); returns the page and the index the scan actually reached.
    function _scanPage(bytes32 skillId, uint256 offset, uint256 end, uint256 resultLimit)
        private
        view
        returns (RankedAgent[] memory ranked, uint256 stoppedAt)
    {
        ranked = new RankedAgent[](resultLimit + end - offset);
        uint256 count;
        uint256 failed;
        uint256 gasPerCandidate = _candidateGas();
        stoppedAt = end;
        for (uint256 i = offset; i < end; ++i) {
            uint256 id = _skillAgents[skillId][i];
            if (!_skills[id][skillId].active) continue;
            if (gasleft() < gasPerCandidate) {
                // Stop the page early rather than misreport a candidate the caller could not afford to read.
                if (i == offset) revert InsufficientCallGas(gasPerCandidate);
                stoppedAt = i;
                break;
            }
            // The official registry has no public burn operation; ownership transfers preserve identity history.
            _agentOwner(id);
            RankedAgent memory entry = _rank(id, skillId);
            if (entry.unavailable) {
                // Unavailable candidates are appended after the scored list once its final length is known.
                ranked[resultLimit + failed++] = entry;
                continue;
            }
            count = _insert(ranked, count, resultLimit, entry);
        }
        for (uint256 j; j < failed; ++j) {
            ranked[count + j] = ranked[resultLimit + j];
        }
        // Only truncate an allocated memory array; its elements and their pointers remain intact.
        assembly ("memory-safe") {
            mstore(ranked, add(count, failed))
        }
    }

    /// @dev Insertion into a descending list capped at resultLimit; ties use the lower agent ID first.
    function _insert(
        RankedAgent[] memory ranked,
        uint256 count,
        uint256 resultLimit,
        RankedAgent memory entry
    ) private pure returns (uint256) {
        uint256 position = count;
        for (uint256 j; j < count; ++j) {
            if (
                entry.score.total > ranked[j].score.total
                    || (entry.score.total == ranked[j].score.total && entry.agentId < ranked[j].agentId)
            ) {
                position = j;
                break;
            }
        }
        if (position >= resultLimit) return count;
        if (count < resultLimit) ++count;
        for (uint256 j = count - 1; j > position; --j) {
            ranked[j] = ranked[j - 1];
        }
        ranked[position] = entry;
        return count;
    }

    function _rank(uint256 agentId, bytes32 skillId) private view returns (RankedAgent memory entry) {
        entry.agentId = agentId;
        bool ok;
        (ok, entry.unavailableSource, entry.score) = _tryScore(agentId, skillId);
        entry.unavailable = !ok;
        if (ok) entry.unavailableSource = address(0);
    }

    /// @dev Reverting variant for single-agent reads: an unavailable source is an explicit error, never zero.
    function _score(uint256 agentId, bytes32 skillId) private view returns (ScoreBreakdown memory s) {
        bool ok;
        address source;
        (ok, source, s) = _tryScore(agentId, skillId);
        if (!ok) revert ScoreSourceUnavailable(source, agentId);
    }

    /// @dev Gas one candidate needs so that every budgeted read receives its full budget (EIP-150 keeps 1/64).
    function _candidateGas() private view returns (uint256) {
        uint256 perRead = _readGas(sourceGasBudget);
        return address(workHistory) == address(0) ? perRead : 2 * perRead;
    }

    function _readGas(uint256 budget) private pure returns (uint256) {
        return budget + budget / 63 + CALL_GAS_RESERVE;
    }

    /// @dev Budgeted STATICCALL with explicit return-data validation, so a source that reverts, runs out of
    /// its budget, or answers with the wrong shape is reported instead of decoded into a wrong score.
    /// Reverts InsufficientCallGas when the caller itself cannot fund the budget: that is the caller's gas,
    /// not the source's failure.
    function _budgetedRead(address source, bytes memory data, uint256 words)
        private
        view
        returns (bool ok, bytes memory result)
    {
        uint256 budget = sourceGasBudget;
        uint256 required = _readGas(budget);
        if (gasleft() < required) revert InsufficientCallGas(required);
        (ok, result) = source.staticcall{gas: budget}(data);
        ok = ok && result.length == 32 * words;
    }

    /// @dev Non-reverting scoring used by the leaderboard so one failed source cannot hide every other agent.
    function _tryScore(uint256 agentId, bytes32 skillId)
        private
        view
        returns (bool ok, address source, ScoreBreakdown memory s)
    {
        bytes memory result;
        (ok, result) = _budgetedRead(
            address(REPUTATION_REGISTRY),
            abi.encodeCall(
                IReputationRegistry.getSummary, (agentId, _trustedClients, reputationTag1, reputationTag2)
            ),
            3
        );
        if (ok) {
            (uint256 count, uint256 rawValue, uint256 decimals) =
                abi.decode(result, (uint256, uint256, uint256));
            int256 value = int256(rawValue);
            ok = count <= type(uint64).max && decimals <= 18 && value >= type(int128).min
                && value <= type(int128).max;
            if (ok) {
                s.feedbackCount = uint64(count);
                s.reputationValue = int128(value);
                s.reputationDecimals = uint8(decimals);
                if (count != 0) s.reputationBps = _normalizeRating(int128(value), uint8(decimals));
            }
        }
        if (!ok) return (false, address(REPUTATION_REGISTRY), _empty());
        if (address(workHistory) != address(0)) {
            s.historySource = 1;
            (ok, result) = _budgetedRead(
                address(workHistory), abi.encodeCall(IAgentWorkHistory.getWorkSummary, (agentId)), 2
            );
            if (ok) {
                (uint256 completed, uint256 accepted) = abi.decode(result, (uint256, uint256));
                ok = completed <= type(uint64).max && accepted <= completed;
                if (ok) {
                    s.completedWork = uint64(completed);
                    s.acceptedWork = uint64(accepted);
                    if (completed != 0) {
                        // Acceptance quality multiplied by evidence depth; rejected jobs cannot improve this score.
                        s.historyBps = (accepted * BPS * _min(completed, HISTORY_CONFIDENCE_CAP))
                            / (completed * HISTORY_CONFIDENCE_CAP);
                    }
                }
            }
            if (!ok) return (false, address(workHistory), _empty());
        } else {
            // Historical rating evidence is an explicitly labeled fallback, never a claim of accepted jobs.
            s.historyBps =
                s.reputationBps * _min(s.feedbackCount, HISTORY_CONFIDENCE_CAP) / HISTORY_CONFIDENCE_CAP;
        }
        s.endorsements = _skills[agentId][skillId].endorsements;
        s.reputationPoints = s.reputationBps * REPUTATION_WEIGHT / BPS;
        s.historyPoints = s.historyBps * HISTORY_WEIGHT / BPS;
        s.endorsementPoints = _min(s.endorsements, ENDORSEMENT_CAP) * ENDORSEMENT_WEIGHT / ENDORSEMENT_CAP;
        s.total = s.reputationPoints + s.historyPoints + s.endorsementPoints;
        s.policyVersion = policyVersion;
    }

    /// @dev An unavailable candidate carries no partial figures that a client could mistake for a score.
    function _empty() private pure returns (ScoreBreakdown memory s) {}

    /// @dev Clamp negative scores to zero and values over 100 to full scale before multiplying.
    function _normalizeRating(int128 value, uint8 decimals) private pure returns (uint256) {
        if (value <= 0) return 0;
        uint256 scale = 10 ** uint256(decimals);
        uint256 positive = uint256(uint128(value));
        if (positive >= 100 * scale) return BPS;
        return positive * 100 / scale;
    }

    function _pageEnd(uint256 offset, uint256 limit, uint256 total) private pure returns (uint256) {
        if (limit == 0 || limit > MAX_SCAN || offset > total) revert InvalidPage();
        return offset + _min(limit, total - offset);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
