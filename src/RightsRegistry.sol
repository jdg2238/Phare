// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IRightsRegistry} from "./interfaces/IRightsRegistry.sol";
import {IncomeType, SplitEntry, SplitSet} from "./Types.sol";

/// @title RightsRegistry — LEVEL 0 of the dependency graph (§5)
/// @notice Catalogues, tracks, ownership, ISRC/ISWC anchors, split sets keyed by IncomeType (cl. 3.2),
///         collaborator confirmation (cl. 5.1) and derivatives (cl. 2.3). Everything else gates on it.
/// @dev UUPS-upgradeable (§6). Only hashes of identifiers are held on-chain (I20).
contract RightsRegistry is IRightsRegistry, Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    // ---------------------------------------------------------------------
    // Roles
    // ---------------------------------------------------------------------
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE"); // PHARE onboarding
    bytes32 public constant LEDGER_ROLE = keccak256("LEDGER_ROLE"); // ClearanceLedger → registerDerivative
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint16 public constant BPS_DENOMINATOR = 10_000;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    struct Track {
        bool exists;
        address owner; // rights holder (master + composition for a production library)
        bool ownershipConfirmed; // owner has confirmed on-chain
        uint8 rightsMask; // Rights.*
        bytes32 isrcHash; // keccak256(ISRC) — anchor only
        bytes32 iswcHash; // keccak256(ISWC) — anchor only
        bytes32 titleHash; // keccak256(normalised title) — cl. 3.1(iii)
        bytes32 parentTrackId; // non-zero for Edited Material (cl. 2.3)
        bytes32 editId; // the edit that produced this derivative
        bytes32 contentHash; // derivative content fingerprint
        uint64 registeredAt;
    }

    struct Catalogue {
        bool exists;
        address owner;
        bytes32[] tracks;
    }

    mapping(bytes32 trackId => Track) private _tracks;
    mapping(bytes32 catalogueId => Catalogue) private _catalogues;
    mapping(bytes32 catalogueId => mapping(bytes32 trackId => bool)) private _inCatalogue;
    mapping(bytes32 trackId => mapping(uint8 incomeType => SplitSet)) private _splits;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event CatalogueCreated(bytes32 indexed catalogueId, address indexed owner);
    event TrackRegistered(bytes32 indexed trackId, address indexed owner, uint8 rightsMask, bytes32 titleHash);
    event OwnershipConfirmed(bytes32 indexed trackId, address indexed owner);
    event TitleHashUpdated(bytes32 indexed trackId, bytes32 titleHash);
    event TrackAddedToCatalogue(bytes32 indexed catalogueId, bytes32 indexed trackId);
    event TrackRemovedFromCatalogue(bytes32 indexed catalogueId, bytes32 indexed trackId);
    event SplitSetProposed(bytes32 indexed trackId, uint8 indexed incomeType, uint256 entries, address residualPayee);
    event SplitConfirmed(bytes32 indexed trackId, uint8 indexed incomeType, address indexed payee);
    event SplitsLocked(bytes32 indexed trackId, uint8 indexed incomeType);
    event DerivativeRegistered(
        bytes32 indexed parentTrackId, bytes32 indexed derivativeTrackId, bytes32 editId, address indexed owner
    );

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error CatalogueExists(bytes32 catalogueId);
    error CatalogueUnknown(bytes32 catalogueId);
    error TrackExists(bytes32 trackId);
    error TrackUnknown(bytes32 trackId);
    error NotTrackOwner(bytes32 trackId, address caller);
    error NotCatalogueOwner(bytes32 catalogueId, address caller);
    error InvalidIncomeType(uint8 incomeType);
    error InvalidSplitSum(uint256 sum); // I4
    error InvalidSplitEntry(uint256 index);
    error DuplicatePayee(address payee);
    error NoSplitSet(bytes32 trackId, uint8 incomeType);
    error NotAPayee(bytes32 trackId, uint8 incomeType, address caller);
    error ZeroAddress();
    error ZeroId();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRAR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ---------------------------------------------------------------------
    // Catalogues (Key Terms "Track(s)": any track in the Production Music Library)
    // ---------------------------------------------------------------------

    function createCatalogue(bytes32 catalogueId, address owner) external onlyRole(REGISTRAR_ROLE) {
        if (catalogueId == bytes32(0)) revert ZeroId();
        if (owner == address(0)) revert ZeroAddress();
        if (_catalogues[catalogueId].exists) revert CatalogueExists(catalogueId);
        _catalogues[catalogueId].exists = true;
        _catalogues[catalogueId].owner = owner;
        emit CatalogueCreated(catalogueId, owner);
    }

    function addToCatalogue(bytes32 catalogueId, bytes32 trackId) external {
        Catalogue storage c = _requireCatalogue(catalogueId);
        _onlyCatalogueOwnerOrRegistrar(catalogueId, c.owner);
        if (!_tracks[trackId].exists) revert TrackUnknown(trackId);
        if (_inCatalogue[catalogueId][trackId]) return;
        _inCatalogue[catalogueId][trackId] = true;
        c.tracks.push(trackId);
        emit TrackAddedToCatalogue(catalogueId, trackId);
    }

    function removeFromCatalogue(bytes32 catalogueId, bytes32 trackId) external {
        Catalogue storage c = _requireCatalogue(catalogueId);
        _onlyCatalogueOwnerOrRegistrar(catalogueId, c.owner);
        if (!_inCatalogue[catalogueId][trackId]) return;
        _inCatalogue[catalogueId][trackId] = false;
        uint256 n = c.tracks.length;
        for (uint256 i = 0; i < n; i++) {
            if (c.tracks[i] == trackId) {
                c.tracks[i] = c.tracks[n - 1];
                c.tracks.pop();
                break;
            }
        }
        emit TrackRemovedFromCatalogue(catalogueId, trackId);
    }

    function catalogueOwner(bytes32 catalogueId) external view returns (address) {
        return _catalogues[catalogueId].owner;
    }

    function catalogueExists(bytes32 catalogueId) external view returns (bool) {
        return _catalogues[catalogueId].exists;
    }

    /// @dev Member tracks; used by ApportionmentPolicy.PRO_RATA_CATALOGUE (OPEN-Q7).
    function catalogueTracks(bytes32 catalogueId) external view returns (bytes32[] memory) {
        return _catalogues[catalogueId].tracks;
    }

    function isInCatalogue(bytes32 catalogueId, bytes32 trackId) public view override returns (bool) {
        return _inCatalogue[catalogueId][trackId];
    }

    // ---------------------------------------------------------------------
    // Tracks
    // ---------------------------------------------------------------------

    /// @notice Register a track. Ownership is confirmed immediately when the registrar is the owner;
    ///         otherwise the named owner must call {confirmOwnership} (cl. 5.1).
    function registerTrack(
        bytes32 trackId,
        address owner,
        uint8 rightsMask,
        bytes32 isrcHash,
        bytes32 iswcHash,
        bytes32 titleHash_
    ) external onlyRole(REGISTRAR_ROLE) {
        if (trackId == bytes32(0)) revert ZeroId();
        if (owner == address(0)) revert ZeroAddress();
        if (_tracks[trackId].exists) revert TrackExists(trackId);
        Track storage t = _tracks[trackId];
        t.exists = true;
        t.owner = owner;
        t.ownershipConfirmed = (owner == msg.sender);
        t.rightsMask = rightsMask;
        t.isrcHash = isrcHash;
        t.iswcHash = iswcHash;
        t.titleHash = titleHash_;
        t.registeredAt = uint64(block.timestamp);
        emit TrackRegistered(trackId, owner, rightsMask, titleHash_);
        if (t.ownershipConfirmed) emit OwnershipConfirmed(trackId, owner);
    }

    function confirmOwnership(bytes32 trackId) external {
        Track storage t = _requireTrack(trackId);
        if (t.owner != msg.sender) revert NotTrackOwner(trackId, msg.sender);
        t.ownershipConfirmed = true;
        emit OwnershipConfirmed(trackId, msg.sender);
    }

    function setTitleHash(bytes32 trackId, bytes32 titleHash_) external {
        Track storage t = _requireTrack(trackId);
        if (t.owner != msg.sender) revert NotTrackOwner(trackId, msg.sender);
        t.titleHash = titleHash_;
        emit TitleHashUpdated(trackId, titleHash_);
    }

    function trackInfo(bytes32 trackId) external view returns (Track memory) {
        return _tracks[trackId];
    }

    function ownerOfTrack(bytes32 trackId) external view override returns (address) {
        return _tracks[trackId].owner;
    }

    function rightsOfTrack(bytes32 trackId) external view returns (uint8) {
        return _tracks[trackId].rightsMask;
    }

    function titleHash(bytes32 trackId) external view override returns (bytes32) {
        return _tracks[trackId].titleHash;
    }

    /// @notice cl. 5.1 — the Licensor's warranty made checkable per track: the track exists, the
    ///         owner has confirmed, and every SYNC collaborator has confirmed their split.
    function isFullyRegistered(bytes32 trackId) public view override returns (bool) {
        Track storage t = _tracks[trackId];
        return t.exists && t.ownershipConfirmed && allSplitsConfirmed(trackId, uint8(IncomeType.SYNC));
    }

    // ---------------------------------------------------------------------
    // Split sets — keyed by IncomeType (cl. 3.2); Σ bps == 10_000 (I4)
    // ---------------------------------------------------------------------

    /// @notice Propose (or replace) the split table for one income type. Resets confirmations; the
    ///         proposer's own line is confirmed automatically, every other payee must {confirmSplit}.
    function setSplitSet(bytes32 trackId, uint8 incomeType, SplitEntry[] calldata entries, address residualPayee)
        external
    {
        Track storage t = _requireTrack(trackId);
        if (t.owner != msg.sender) revert NotTrackOwner(trackId, msg.sender);
        _requireIncomeType(incomeType);
        if (residualPayee == address(0)) revert ZeroAddress();
        if (entries.length == 0) revert InvalidSplitEntry(0);

        SplitSet storage ss = _splits[trackId][incomeType];
        delete ss.entries;

        uint256 sum;
        bool allConfirmed = true;
        for (uint256 i = 0; i < entries.length; i++) {
            SplitEntry calldata e = entries[i];
            if (e.payee == address(0) || e.bps == 0) revert InvalidSplitEntry(i);
            for (uint256 j = 0; j < i; j++) {
                if (entries[j].payee == e.payee) revert DuplicatePayee(e.payee);
            }
            sum += e.bps;
            bool confirmed = (e.payee == msg.sender);
            if (!confirmed) allConfirmed = false;
            ss.entries.push(SplitEntry({payee: e.payee, bps: e.bps, partyId: e.partyId, confirmed: confirmed}));
        }
        if (sum != BPS_DENOMINATOR) revert InvalidSplitSum(sum); // I4

        ss.residualPayee = residualPayee;
        ss.locked = allConfirmed;
        emit SplitSetProposed(trackId, incomeType, entries.length, residualPayee);
        if (allConfirmed) emit SplitsLocked(trackId, incomeType);
    }

    /// @notice cl. 5.1 — a collaborator confirms their line. The set locks when every line is confirmed.
    function confirmSplit(bytes32 trackId, uint8 incomeType) external {
        _requireTrack(trackId);
        _requireIncomeType(incomeType);
        SplitSet storage ss = _splits[trackId][incomeType];
        if (ss.entries.length == 0) revert NoSplitSet(trackId, incomeType);
        bool found;
        bool allConfirmed = true;
        for (uint256 i = 0; i < ss.entries.length; i++) {
            if (ss.entries[i].payee == msg.sender) {
                ss.entries[i].confirmed = true;
                found = true;
            }
            if (!ss.entries[i].confirmed) allConfirmed = false;
        }
        if (!found) revert NotAPayee(trackId, incomeType, msg.sender);
        emit SplitConfirmed(trackId, incomeType, msg.sender);
        if (allConfirmed && !ss.locked) {
            ss.locked = true;
            emit SplitsLocked(trackId, incomeType);
        }
    }

    function allSplitsConfirmed(bytes32 trackId, uint8 incomeType) public view override returns (bool) {
        SplitSet storage ss = _splits[trackId][incomeType];
        return ss.entries.length > 0 && ss.locked;
    }

    function splitSet(bytes32 trackId, uint8 incomeType) external view override returns (SplitSet memory) {
        _requireIncomeType(incomeType);
        return _splits[trackId][incomeType];
    }

    // ---------------------------------------------------------------------
    // Derivatives — cl. 2.3: Edited Material vests in the Licensor (I8)
    // ---------------------------------------------------------------------

    /// @notice Called by the ClearanceLedger on {registerEdit}. The derivative's owner is the assignee
    ///         (the Licensor) and there is no function that can change it.
    function registerDerivative(bytes32 parentTrackId, bytes32 editId, address assignee, bytes32 contentHash)
        external
        override
        onlyRole(LEDGER_ROLE)
        returns (bytes32 derivativeTrackId)
    {
        Track storage parent = _requireTrack(parentTrackId);
        if (assignee == address(0)) revert ZeroAddress();
        if (editId == bytes32(0)) revert ZeroId();
        derivativeTrackId = keccak256(abi.encode(parentTrackId, editId));
        if (_tracks[derivativeTrackId].exists) revert TrackExists(derivativeTrackId);
        Track storage d = _tracks[derivativeTrackId];
        d.exists = true;
        d.owner = assignee;
        d.ownershipConfirmed = true;
        d.rightsMask = parent.rightsMask;
        d.isrcHash = bytes32(0);
        d.iswcHash = parent.iswcHash;
        d.titleHash = parent.titleHash;
        d.parentTrackId = parentTrackId;
        d.editId = editId;
        d.contentHash = contentHash;
        d.registeredAt = uint64(block.timestamp);
        emit DerivativeRegistered(parentTrackId, derivativeTrackId, editId, assignee);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _requireTrack(bytes32 trackId) private view returns (Track storage t) {
        t = _tracks[trackId];
        if (!t.exists) revert TrackUnknown(trackId);
    }

    function _requireCatalogue(bytes32 catalogueId) private view returns (Catalogue storage c) {
        c = _catalogues[catalogueId];
        if (!c.exists) revert CatalogueUnknown(catalogueId);
    }

    function _onlyCatalogueOwnerOrRegistrar(bytes32 catalogueId, address owner) private view {
        if (msg.sender != owner && !hasRole(REGISTRAR_ROLE, msg.sender)) {
            revert NotCatalogueOwner(catalogueId, msg.sender);
        }
    }

    function _requireIncomeType(uint8 incomeType) private pure {
        if (incomeType > uint8(IncomeType.OTHER)) revert InvalidIncomeType(incomeType);
    }
}
