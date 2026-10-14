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
/// The owner selects feedback publishers/metric and an optional work adapter, never individual scores.
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
    /// @notice Maximum distinct skills ever registered by an agent, including hidden skills.
    uint256 public constant MAX_AGENT_SKILLS = 32;
    /// @notice Maximum skill label length in ASCII bytes before normalization.
    uint256 public constant MAX_SKILL_LENGTH = 48;
    /// @notice Maximum trusted feedback publishers.
    uint256 public constant MAX_CLIENTS = 32;
    /// @notice Maximum candidates scanned in one ranking page.
    uint256 public constant MAX_SCAN = 50;
    /// @notice Maximum ranked results returned in one page.
    uint256 public constant MAX_RESULTS = 20;
    /// @notice Per external score-source gas cap; source exhaustion produces an explicit error.
    uint256 public constant SOURCE_GAS_LIMIT = 2_000_000;

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
    struct RankedAgent {
        uint256 agentId;
        ScoreBreakdown score;
    }

    struct SkillState {
        bool known;
        bool active;
        uint256 endorsements;
    }

    /// @notice Optional authoritative work ledger adapter; unset means historical-feedback mode.
    IAgentWorkHistory public workHistory;
    /// @notice Primary quality metric tag; must use 0..100 units. ERC-8004's suggested default is starred.
    string public reputationTag1 = "starred";
    /// @notice Optional secondary metric filter; empty means all secondary tags within the primary metric.
    string public reputationTag2;
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

    /// @notice Selects the actual 0..100 quality metric used by the chosen publishers.
    /// @param tag1 Nonempty primary metric, at most 48 bytes; defaults to ERC-8004's starred metric.
    /// @param tag2 Optional secondary metric, at most 48 bytes.
    /// @dev Never select mixed units, latency, revenue, or binary outcomes as a percentage rating.
    function setReputationMetric(string calldata tag1, string calldata tag2) external onlyOwner {
        if (bytes(tag1).length == 0 || bytes(tag1).length > 48 || bytes(tag2).length > 48) {
            revert InvalidPolicy();
        }
        reputationTag1 = tag1;
        reputationTag2 = tag2;
        emit ReputationMetricChanged(tag1, tag2, ++policyVersion);
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
    function registerSkill(uint256 agentId, string calldata name) external returns (bytes32 skillId) {
        _requireOwner(agentId);
        string memory canonical;
        (skillId, canonical) = normalizeSkill(name);
        SkillState storage state = _skills[agentId][skillId];
        if (state.active) revert SkillAlreadyActive();
        if (!state.known) {
            if (_agentSkills[agentId].length >= MAX_AGENT_SKILLS) revert SkillLimitReached();
            state.known = true;
            _agentSkills[agentId].push(skillId);
            _skillAgents[skillId].push(agentId);
            if (bytes(_skillNames[skillId]).length == 0) {
                _skillNames[skillId] = canonical;
                _catalog.push(skillId);
            }
        }
        state.active = true;
        emit SkillRegistered(agentId, skillId, canonical);
    }

    /// @notice Hides a skill from discovery without resetting endorsements or consuming a new slot later.
    /// @param agentId Identity owned by the caller.
    /// @param skillId Canonical skill hash.
    function hideSkill(uint256 agentId, bytes32 skillId) external {
        _requireOwner(agentId);
        if (!_skills[agentId][skillId].active) revert SkillNotActive();
        _skills[agentId][skillId].active = false;
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
    /// @return skills Canonical names, hashes, and unique endorsement counts, in registration order.
    function getAgentSkills(uint256 agentId) external view returns (Skill[] memory skills) {
        _agentOwner(agentId);
        bytes32[] storage ids = _agentSkills[agentId];
        uint256 count;
        for (uint256 i; i < ids.length; ++i) {
            if (_skills[agentId][ids[i]].active) ++count;
        }
        skills = new Skill[](count);
        count = 0;
        for (uint256 i; i < ids.length; ++i) {
            bytes32 id = ids[i];
            if (_skills[agentId][id].active) {
                skills[count++] = Skill(id, _skillNames[id], _skills[agentId][id].endorsements);
            }
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
    /// @return ranked Top candidates within this page; ties use lower agent ID first.
    /// @return nextOffset Cursor for the next page.
    /// @return totalCandidates All historical candidates, including hidden registrations.
    /// @dev For GLOBAL top K, merge every page's top K at the SAME block. No cap on total registrations.
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
        uint256[] storage candidates = _skillAgents[skillId];
        totalCandidates = candidates.length;
        nextOffset = _pageEnd(offset, scanLimit, totalCandidates);
        ranked = new RankedAgent[](resultLimit);
        uint256 count;
        for (uint256 i = offset; i < nextOffset; ++i) {
            uint256 id = candidates[i];
            if (!_skills[id][skillId].active) continue;
            // The official registry has no public burn operation; ownership transfers preserve identity history.
            _agentOwner(id);
            ScoreBreakdown memory score = _score(id, skillId);
            uint256 position = count;
            for (uint256 j; j < count; ++j) {
                if (
                    score.total > ranked[j].score.total
                        || (score.total == ranked[j].score.total && id < ranked[j].agentId)
                ) {
                    position = j;
                    break;
                }
            }
            if (position >= resultLimit) continue;
            if (count < resultLimit) ++count;
            for (uint256 j = count - 1; j > position; --j) {
                ranked[j] = ranked[j - 1];
            }
            ranked[position] = RankedAgent(id, score);
        }
        // Only truncate an allocated memory array; its elements and their pointers remain intact.
        assembly ("memory-safe") {
            mstore(ranked, count)
        }
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

    function _score(uint256 agentId, bytes32 skillId) private view returns (ScoreBreakdown memory s) {
        try REPUTATION_REGISTRY.getSummary{gas: SOURCE_GAS_LIMIT}(
            agentId, _trustedClients, reputationTag1, reputationTag2
        ) returns (
            uint64 count, int128 value, uint8 decimals
        ) {
            if (decimals > 18) revert ScoreSourceUnavailable(address(REPUTATION_REGISTRY), agentId);
            s.feedbackCount = count;
            s.reputationValue = value;
            s.reputationDecimals = decimals;
            if (count != 0) s.reputationBps = _normalizeRating(value, decimals);
        } catch {
            revert ScoreSourceUnavailable(address(REPUTATION_REGISTRY), agentId);
        }
        if (address(workHistory) != address(0)) {
            s.historySource = 1;
            try workHistory.getWorkSummary{gas: SOURCE_GAS_LIMIT}(agentId) returns (
                uint64 completed, uint64 accepted
            ) {
                if (accepted > completed) revert ScoreSourceUnavailable(address(workHistory), agentId);
                s.completedWork = completed;
                s.acceptedWork = accepted;
                if (completed != 0) {
                    // Acceptance quality multiplied by evidence depth; rejected jobs cannot improve this score.
                    s.historyBps = (uint256(accepted) * BPS * _min(completed, HISTORY_CONFIDENCE_CAP))
                        / (uint256(completed) * HISTORY_CONFIDENCE_CAP);
                }
            } catch {
                revert ScoreSourceUnavailable(address(workHistory), agentId);
            }
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
