// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IClearanceLedger} from "./interfaces/IClearanceLedger.sol";
import {SubscriptionLicence721} from "./SubscriptionLicence721.sol";
import {RightsRegistry} from "./RightsRegistry.sol";
import {TerritoryLib} from "./libraries/TerritoryLib.sol";
import {
    Licence,
    LicenceTerms,
    LicenceState,
    LicenceScope,
    BindingTrigger,
    Attestation,
    AuthorisedParty,
    DeclarationInput,
    SyncDeclaration,
    UndeclaredUse,
    EditedMaterial,
    UsageReport,
    BreachAllegation
} from "./Types.sol";

/// @title ClearanceLedger — LEVEL 4/5 of the dependency graph (§5)
/// @notice The per-Production clearance record and the public read surface. Separate from the token
///         on purpose: declarations must outlive the token's state (cl. 9.2) and be queryable by third
///         parties with no interest in the subscription. {verifyClearance} never consults licence state.
/// @dev UUPS-upgradeable (§6). Records are minimal (ids + hashes + timestamp); descriptive data is off-chain.
contract ClearanceLedger is IClearanceLedger, Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using TerritoryLib for *;

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE"); // PHARE content protection (OPEN-Q13)
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE"); // OPEN-Q9
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    SubscriptionLicence721 public licence;
    RightsRegistry public registry;

    mapping(bytes32 declarationId => SyncDeclaration) private _declarations;
    mapping(uint256 licenceId => bytes32[]) private _declarationsOf;
    UndeclaredUse[] private _undeclared;
    mapping(bytes32 editId => EditedMaterial) private _edits;
    mapping(bytes32 editId => bool) public editChallengeUpheld;
    mapping(uint256 licenceId => UsageReport[]) private _reports;
    mapping(uint256 licenceId => uint256) private _outstanding;
    BreachAllegation[] private _allegations;

    event EditChallengeResolved(bytes32 indexed editId, bool upheld);

    error ZeroAddress();
    error LicenceCannotDeclare(uint256 licenceId); // I13
    error NotAuthorisedDeclarer(uint256 licenceId, address caller); // cl. 2.6
    error InvalidProductionOwner(uint256 licenceId, address owner); // cl. 2.5(i)
    error TrackNotInCatalogue(bytes32 catalogueId, bytes32 trackId); // I3
    error TrackNotLicensed(bytes32 trackId);
    error TrackNotFullyRegistered(bytes32 trackId); // I2 / cl. 5.1
    error ContentOutOfScope(uint16 requested, uint16 permitted); // I10
    error MediaOutOfScope(uint32 requested, uint32 permitted); // I10 / I10b
    error MissingAttestations(uint8 given, uint8 required); // I10d
    error OutOfContextUse(bytes32 derivedFromProductionId); // I10c / cl. 3.1(iv)
    error TitleUseUnconfirmed(bytes32 trackId); // I10e / cl. 3.1(iii)
    error AlreadyDeclared(bytes32 declarationId);
    error DeclarationUnknown(bytes32 declarationId);
    error EditingNotPermitted(uint256 licenceId); // I9
    error EditExists(bytes32 editId);
    error EditUnknown(bytes32 editId);
    error NotLicensor(uint256 licenceId, address caller);
    error InvalidCovenant(uint8 covenant);
    error DeclarationMismatch(uint256 licenceId, bytes32 declarationId);
    error ZeroId();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, SubscriptionLicence721 licence_, RightsRegistry registry_) external initializer {
        if (admin == address(0) || address(licence_) == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        __AccessControl_init();
        licence = licence_;
        registry = registry_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ---------------------------------------------------------------------
    // cl. 2.2 / 2.5 / 2.6 / 3.1 / 5.1 — declareSync
    // ---------------------------------------------------------------------

    /// @inheritdoc IClearanceLedger
    function declareSync(DeclarationInput calldata input) external override returns (bytes32 declarationId) {
        uint256 licenceId = input.licenceId;
        Licence memory l = licence.licenceOf(licenceId);

        // cl. 2.6 — only the Licensee or an authorised party may declare.
        if (!licence.isAuthorised(licenceId, msg.sender)) revert NotAuthorisedDeclarer(licenceId, msg.sender);

        // cl. 6.3 — the first sync binds an ISSUED licence.
        if (l.state == LicenceState.ISSUED) {
            licence.bind(licenceId, uint8(BindingTrigger.FIRST_SYNC));
        }
        if (!licence.canDeclare(licenceId)) revert LicenceCannotDeclare(licenceId); // I13

        LicenceTerms memory t = l.terms;

        // cl. 2.5(i) — the Production is owned by the Licensee, a group company or an advertising client.
        _requireProductionOwner(licenceId, l.licensee, input.productionOwner);

        // Key Terms — the track must be one the licence covers.
        if (t.scope == LicenceScope.CATALOGUE) {
            if (!registry.isInCatalogue(t.catalogueId, input.trackId)) {
                revert TrackNotInCatalogue(t.catalogueId, input.trackId); // I3
            }
        } else if (input.trackId != t.trackId) {
            revert TrackNotLicensed(input.trackId);
        }

        // cl. 5.1 — the Licensor's warranty, checked per track at the moment of use.
        if (!registry.isFullyRegistered(input.trackId)) revert TrackNotFullyRegistered(input.trackId); // I2

        // cl. 2.2 / 3.1(i) — default-deny scope check on content and media (I10, I10b).
        if (input.contentMask == 0 || (input.contentMask & ~t.contentMask) != 0) {
            revert ContentOutOfScope(input.contentMask, t.contentMask);
        }
        if (input.mediaMask == 0 || (input.mediaMask & ~t.mediaMask) != 0) {
            revert MediaOutOfScope(input.mediaMask, t.mediaMask);
        }

        // cl. 3.1 — self-attestation of the qualitative covenants (I10d).
        if ((input.attestations & Attestation.REQUIRED_BASE) != Attestation.REQUIRED_BASE) {
            revert MissingAttestations(input.attestations, Attestation.REQUIRED_BASE);
        }

        // cl. 3.1(iv) — a declared out-of-context use IS a breach by definition (I10c).
        if (input.derivedFromProductionId != bytes32(0) && !t.outOfContextPermitted) {
            revert OutOfContextUse(input.derivedFromProductionId);
        }

        // cl. 3.1(iii) — title match is flagged, never blocked on the match alone (I10e).
        bool flagged =
            input.productionTitleHash != bytes32(0) && input.productionTitleHash == registry.titleHash(input.trackId);
        if (flagged && !t.titleUsePermitted && (input.attestations & Attestation.TITLE_USE_CONFIRMED) == 0) {
            revert TitleUseUnconfirmed(input.trackId);
        }

        declarationId = keccak256(abi.encode(licenceId, input.trackId, input.productionId));
        if (_declarations[declarationId].declarationId != bytes32(0)) revert AlreadyDeclared(declarationId);

        _declarations[declarationId] = SyncDeclaration({
            declarationId: declarationId,
            licenceId: licenceId,
            trackId: input.trackId,
            productionId: input.productionId,
            productionTitleHash: input.productionTitleHash,
            derivedFromProductionId: input.derivedFromProductionId,
            declaredBy: msg.sender,
            productionOwner: input.productionOwner,
            contentMask: input.contentMask,
            mediaMask: input.mediaMask,
            attestations: input.attestations,
            titleUseFlagged: flagged,
            declaredAt: uint64(block.timestamp),
            metadataHash: input.metadataHash,
            distributionPerpetual: t.distributionPerpetual
        });
        _declarationsOf[licenceId].push(declarationId);

        emit SyncDeclared(
            declarationId,
            licenceId,
            input.trackId,
            input.productionId,
            msg.sender,
            input.attestations,
            uint64(block.timestamp)
        );
        if (flagged) emit TitleUseFlagged(declarationId, input.trackId, input.productionTitleHash);
    }

    /// @inheritdoc IClearanceLedger
    /// @dev cl. 9.2 — TRUE forever for a valid declaration. Reads the immutable terms for the
    ///      distribution territory / term, and NEVER the licence state (I12).
    function verifyClearance(bytes32 declarationId, bytes2 iso, uint32 mediaBit) external view override returns (bool) {
        SyncDeclaration storage d = _declarations[declarationId];
        if (d.declarationId == bytes32(0)) return false;
        if (mediaBit == 0 || (mediaBit & ~d.mediaMask) != 0) return false;
        LicenceTerms memory t = licence.termsOf(d.licenceId);
        if (iso != bytes2(0) && !t.distributionTerritory.contains(iso)) return false;
        if (!d.distributionPerpetual && block.timestamp > t.distributionTermEnd) return false;
        return true;
    }

    /// @inheritdoc IClearanceLedger
    function declaration(bytes32 declarationId) external view override returns (SyncDeclaration memory) {
        return _declarations[declarationId];
    }

    function declarationIdsOf(uint256 licenceId) external view returns (bytes32[] memory) {
        return _declarationsOf[licenceId];
    }

    function declarationCount(uint256 licenceId) external view returns (uint256) {
        return _declarationsOf[licenceId].length;
    }

    // ---------------------------------------------------------------------
    // cl. 3.1(iv) — content-protection oracle (evidence only; I10f)
    // ---------------------------------------------------------------------

    /// @inheritdoc IClearanceLedger
    function reportUndeclaredUse(
        bytes32 trackId,
        bytes32 assetFingerprint,
        uint256 suspectedLicenceId,
        bytes32 evidenceHash
    ) external override onlyRole(ORACLE_ROLE) {
        _undeclared.push(
            UndeclaredUse({
                trackId: trackId,
                assetFingerprint: assetFingerprint,
                suspectedLicenceId: suspectedLicenceId,
                detectedAt: uint64(block.timestamp),
                evidenceHash: evidenceHash
            })
        );
        emit UndeclaredUseDetected(trackId, assetFingerprint, suspectedLicenceId, evidenceHash, uint64(block.timestamp));
    }

    function undeclaredUse(uint256 i) external view returns (UndeclaredUse memory) {
        return _undeclared[i];
    }

    function undeclaredUseCount() external view returns (uint256) {
        return _undeclared.length;
    }

    // ---------------------------------------------------------------------
    // cl. 2.3 — edits: assignment to the Licensor is automatic (I8)
    // ---------------------------------------------------------------------

    /// @inheritdoc IClearanceLedger
    function registerEdit(bytes32 declarationId, bytes32 editId, bytes32 contentHash)
        external
        override
        returns (bytes32 derivativeTrackId)
    {
        if (editId == bytes32(0)) revert ZeroId();
        SyncDeclaration storage d = _declarations[declarationId];
        if (d.declarationId == bytes32(0)) revert DeclarationUnknown(declarationId);
        uint256 licenceId = d.licenceId;
        if (!licence.isAuthorised(licenceId, msg.sender)) revert NotAuthorisedDeclarer(licenceId, msg.sender);
        Licence memory l = licence.licenceOf(licenceId);
        if (!l.terms.editingPermitted) revert EditingNotPermitted(licenceId); // I9
        if (!licence.canDeclare(licenceId)) revert LicenceCannotDeclare(licenceId); // edits happen in the Term
        if (_edits[editId].registeredAt != 0) revert EditExists(editId);

        derivativeTrackId = registry.registerDerivative(d.trackId, editId, l.licensor, contentHash);
        _edits[editId] = EditedMaterial({
            editId: editId,
            declarationId: declarationId,
            parentTrackId: d.trackId,
            owner: l.licensor, // cl. 2.3 — vests in the Licensor; no setter (I8)
            contentHash: contentHash,
            registeredAt: uint64(block.timestamp),
            challenged: false
        });
        emit EditRegistered(declarationId, editId, derivativeTrackId, l.licensor);
    }

    /// @inheritdoc IClearanceLedger
    /// @dev The "no new lyrical or melodic material" proviso is a musicological judgement: ATTESTED,
    ///      challengeable, never auto-decided.
    function challengeEdit(bytes32 editId, bytes32 evidenceHash) external override {
        EditedMaterial storage e = _requireEdit(editId);
        if (msg.sender != e.owner) revert NotLicensor(_declarations[e.declarationId].licenceId, msg.sender);
        e.challenged = true;
        emit EditChallenged(editId, evidenceHash);
    }

    /// @inheritdoc IClearanceLedger
    function resolveEditChallenge(bytes32 editId, bool upheld) external override onlyRole(RESOLVER_ROLE) {
        EditedMaterial storage e = _requireEdit(editId);
        e.challenged = false;
        editChallengeUpheld[editId] = upheld;
        emit EditChallengeResolved(editId, upheld);
    }

    function editedMaterial(bytes32 editId) external view returns (EditedMaterial memory) {
        return _edits[editId];
    }

    // ---------------------------------------------------------------------
    // cl. 4 — reporting (declarations are the continuous report; this is the formal one on request)
    // ---------------------------------------------------------------------

    /// @inheritdoc IClearanceLedger
    function requestUsageReport(uint256 licenceId) external override {
        if (msg.sender != licence.licensorOf(licenceId)) revert NotLicensor(licenceId, msg.sender);
        _reports[licenceId].push(
            UsageReport({
                licenceId: licenceId,
                requestedAt: uint64(block.timestamp),
                submittedAt: 0,
                reportHash: bytes32(0),
                reportURI: ""
            })
        );
        _outstanding[licenceId] += 1;
        emit UsageReportRequested(licenceId, uint64(block.timestamp));
    }

    /// @inheritdoc IClearanceLedger
    /// @dev Fills the oldest outstanding request; with none outstanding the report is voluntary.
    function submitUsageReport(uint256 licenceId, bytes32 reportHash, string calldata uri) external override {
        if (!licence.isAuthorised(licenceId, msg.sender)) revert NotAuthorisedDeclarer(licenceId, msg.sender);
        UsageReport[] storage reports = _reports[licenceId];
        if (_outstanding[licenceId] > 0) {
            for (uint256 i = 0; i < reports.length; i++) {
                if (reports[i].submittedAt == 0) {
                    reports[i].submittedAt = uint64(block.timestamp);
                    reports[i].reportHash = reportHash;
                    reports[i].reportURI = uri;
                    break;
                }
            }
            _outstanding[licenceId] -= 1;
        } else {
            reports.push(
                UsageReport({
                    licenceId: licenceId,
                    requestedAt: 0,
                    submittedAt: uint64(block.timestamp),
                    reportHash: reportHash,
                    reportURI: uri
                })
            );
        }
        emit UsageReportSubmitted(licenceId, reportHash, uint64(block.timestamp));
    }

    /// @inheritdoc IClearanceLedger
    function outstandingReports(uint256 licenceId) external view override returns (uint256) {
        return _outstanding[licenceId];
    }

    function usageReport(uint256 licenceId, uint256 i) external view returns (UsageReport memory) {
        return _reports[licenceId][i];
    }

    function usageReportCount(uint256 licenceId) external view returns (uint256) {
        return _reports[licenceId].length;
    }

    // ---------------------------------------------------------------------
    // cl. 3.1 / 5.5 — breach evidence: an immutable, timestamped record; NO state change (I14)
    // ---------------------------------------------------------------------

    /// @inheritdoc IClearanceLedger
    function allegeBreach(uint256 licenceId, bytes32 declarationId, uint8 covenant, bytes32 evidenceHash)
        external
        override
    {
        if (msg.sender != licence.licensorOf(licenceId)) revert NotLicensor(licenceId, msg.sender);
        if (covenant == 0 || covenant > 8) revert InvalidCovenant(covenant);
        if (declarationId != bytes32(0)) {
            SyncDeclaration storage d = _declarations[declarationId];
            if (d.declarationId == bytes32(0)) revert DeclarationUnknown(declarationId);
            if (d.licenceId != licenceId) revert DeclarationMismatch(licenceId, declarationId);
        }
        _allegations.push(
            BreachAllegation({
                licenceId: licenceId,
                declarationId: declarationId,
                covenant: covenant,
                evidenceHash: evidenceHash,
                allegedAt: uint64(block.timestamp)
            })
        );
        emit BreachAlleged(licenceId, declarationId, covenant, evidenceHash);
    }

    function allegation(uint256 i) external view returns (BreachAllegation memory) {
        return _allegations[i];
    }

    function allegationCount() external view returns (uint256) {
        return _allegations.length;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev cl. 2.5(i): owner ∈ {Licensee, group company (role 3), advertising client (role 2)}.
    ///      Agencies / production contractors (role 1) may declare but may not own the Production.
    function _requireProductionOwner(uint256 licenceId, address licensee, address owner) private view {
        if (owner == licensee) return;
        AuthorisedParty memory ap = licence.authorisedParty(licenceId, owner);
        if (ap.active && (ap.role == 2 || ap.role == 3)) return;
        revert InvalidProductionOwner(licenceId, owner);
    }

    function _requireEdit(bytes32 editId) private view returns (EditedMaterial storage e) {
        e = _edits[editId];
        if (e.registeredAt == 0) revert EditUnknown(editId);
    }
}
