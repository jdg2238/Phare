// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice §7 — one ERC-721 token per executed agreement.
interface ISubscriptionLicence721 {
    // ---- cl. 6.3 — binding by any of four observable events -------------------
    function mintFromProposal(uint256 proposalId, uint8 trigger) external returns (uint256 tokenId);

    // ---- state ------------------------------------------------------------------
    function state(uint256 tokenId) external view returns (uint8);

    /// @dev true iff new SyncDeclarations may be made now.
    function canDeclare(uint256 tokenId) external view returns (bool);

    // ---- cl. 2.6 — authorised parties ------------------------------------------
    function setAuthorisedParty(uint256 tokenId, address party, uint8 role, bool active) external;
    function isAuthorised(uint256 tokenId, address who) external view returns (bool);

    // ---- cl. 7 — assignment ------------------------------------------------------
    function setAffiliate(uint256 tokenId, address affiliate, bool isAffiliate) external; // licensee
    function consentToTransfer(uint256 tokenId, address to, uint64 validUntil) external; // licensor
    // transfers: to affiliate → free; to consented address → ok; otherwise revert (cl. 7 "null and void")

    // ---- cl. 9 — exit -----------------------------------------------------------
    function giveNotice(uint256 tokenId) external; // licensee
    function finaliseTermination(uint256 tokenId) external; // anyone, after notice period

    /// @dev cl. 5.5 — ONLY on a carve-out ground. No general breach path exists.
    function rescind(uint256 tokenId, uint8 ground, bytes32 evidenceHash) external; // resolver

    // ---- cl. 6.1 — variation -----------------------------------------------------
    function supersede(uint256 tokenId, uint256 newProposalId) external returns (uint256 newTokenId);

    event LicenceMinted(
        uint256 indexed tokenId,
        address indexed licensor,
        address indexed licensee,
        bytes32 termsHash,
        uint8 trigger,
        uint64 syncTermStart,
        uint64 syncTermEnd
    );
    event AuthorisedPartySet(uint256 indexed tokenId, address party, uint8 role, bool active);
    event TransferConsented(uint256 indexed tokenId, address to, uint64 validUntil);
    event NoticeGiven(uint256 indexed tokenId, uint64 at, uint64 effectiveAt);
    event LicenceStateChanged(uint256 indexed tokenId, uint8 from, uint8 to);
    event Rescinded(uint256 indexed tokenId, uint8 ground, bytes32 evidenceHash);
    event Superseded(uint256 indexed oldTokenId, uint256 indexed newTokenId);
}
