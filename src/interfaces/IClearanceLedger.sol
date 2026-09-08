// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DeclarationInput, SyncDeclaration} from "../Types.sol";

/// @notice §7 — the public read surface. Declarations outlive the token's state (cl. 9.2).
interface IClearanceLedger {
    // ---- cl. 2.2 / 2.5 / 2.6 / 5.1 — the per-Production clearance -----------
    /// @dev Reverts unless: licence.canDeclare(); caller is licensee or authorised; track in
    ///      catalogue; track fully registered (5.1); content ⊆ terms.contentMask; media ⊆ terms.mediaMask;
    ///      attestations ⊇ Attestation.REQUIRED_BASE (3.1); derivedFromProductionId == 0 unless
    ///      terms.outOfContextPermitted (3.1(iv)); and, if productionTitleHash == registry.titleHash(trackId),
    ///      attestations includes TITLE_USE_CONFIRMED (3.1(iii)) — flagged, not blocked.
    function declareSync(DeclarationInput calldata input) external returns (bytes32 declarationId);

    // ---- cl. 3.1(iv) — content-protection oracle -------------------------------
    /// @dev Fingerprint match of a licensed track in an asset with no declaration. Evidence only.
    function reportUndeclaredUse(
        bytes32 trackId,
        bytes32 assetFingerprint,
        uint256 suspectedLicenceId,
        bytes32 evidenceHash
    ) external; // ORACLE role

    /// @dev The single call a broadcaster or platform makes. TRUE forever for a valid declaration (cl. 9.2).
    function verifyClearance(bytes32 declarationId, bytes2 iso, uint32 mediaBit) external view returns (bool);

    function declaration(bytes32 declarationId) external view returns (SyncDeclaration memory);

    // ---- cl. 2.3 — edits --------------------------------------------------------
    function registerEdit(bytes32 declarationId, bytes32 editId, bytes32 contentHash)
        external
        returns (bytes32 derivativeTrackId);
    function challengeEdit(bytes32 editId, bytes32 evidenceHash) external; // licensor
    function resolveEditChallenge(bytes32 editId, bool upheld) external; // resolver

    // ---- cl. 4 — reporting ------------------------------------------------------
    function requestUsageReport(uint256 licenceId) external; // licensor
    function submitUsageReport(uint256 licenceId, bytes32 reportHash, string calldata uri) external;
    function outstandingReports(uint256 licenceId) external view returns (uint256);

    // ---- cl. 3.1 — evidence only; NO state change (cl. 5.5) ---------------------
    function allegeBreach(uint256 licenceId, bytes32 declarationId, uint8 covenant, bytes32 evidenceHash) external;

    event SyncDeclared(
        bytes32 indexed declarationId,
        uint256 indexed licenceId,
        bytes32 indexed trackId,
        bytes32 productionId,
        address declaredBy,
        uint8 attestations,
        uint64 at
    );
    event TitleUseFlagged(bytes32 indexed declarationId, bytes32 indexed trackId, bytes32 productionTitleHash);
    event UndeclaredUseDetected(
        bytes32 indexed trackId,
        bytes32 assetFingerprint,
        uint256 indexed suspectedLicenceId,
        bytes32 evidenceHash,
        uint64 at
    );
    event EditRegistered(
        bytes32 indexed declarationId, bytes32 indexed editId, bytes32 derivativeTrackId, address assignedTo
    );
    event EditChallenged(bytes32 indexed editId, bytes32 evidenceHash);
    event UsageReportRequested(uint256 indexed licenceId, uint64 at);
    event UsageReportSubmitted(uint256 indexed licenceId, bytes32 reportHash, uint64 at);
    event BreachAlleged(uint256 indexed licenceId, bytes32 declarationId, uint8 covenant, bytes32 evidenceHash);
}
