// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title PHARE sync-licence canonical data model
/// @notice Mirrors §4 of "PHARE Sync Licence — Contract Map & Implementation Schema" v1.1.
///         Integer minor units throughout; splits in basis points summing to 10_000;
///         timestamps uint64 Unix seconds; ISO 3166-1 alpha-2 as bytes2.

// ---------------------------------------------------------------------------
// §4.1 Enumerations and bitmasks
// ---------------------------------------------------------------------------

enum LicenceScope {
    TRACK,
    CATALOGUE // this agreement: CATALOGUE
}

/// @dev Which pot of money a split table governs (cl. 3.2).
enum IncomeType {
    SYNC, // 0 — this contract's scope
    MASTER_PERFORMANCE, // 1 — PPL, off-chain today
    PUBLISHING_PERFORMANCE, // 2 — PRS/CISAC, off-chain today (cl. 3.2(i))
    MECHANICAL, // 3 — reserved to Licensor (cl. 3.1)
    OTHER // 4
}

/// @dev Which rights the licence covers. This agreement: MASTER | COMPOSITION.
library Rights {
    uint8 constant MASTER = 1 << 0;
    uint8 constant COMPOSITION = 1 << 1;
}

/// @dev Key Terms "Content". Bitmask.
library Content {
    uint16 constant ADVERTISING_PAID = 1 << 0;
    uint16 constant ADVERTISING_UNPAID = 1 << 1;
    uint16 constant GENERAL_INTEREST = 1 << 2;
    uint16 constant EDITORIAL = 1 << 3;
    uint16 constant BUSINESS = 1 << 4;
    uint16 constant NON_PROFIT = 1 << 5;
    uint16 constant CORPORATE = 1 << 6;
    uint16 constant THIS_AGREEMENT = 0x7F; // all seven
}

/// @dev Key Terms "Licensed Media". Bitmask. Bits are deliberately fine-grained so the
///      exclusion in this agreement (long-form VOD / OTT / IPTV / digital TV) is expressible.
library Media {
    uint32 constant ONLINE_SHORT_FORM_VOD = 1 << 0; // YouTube, Facebook — explicitly IN
    uint32 constant ONLINE_SOCIAL_PAID = 1 << 1;
    uint32 constant ONLINE_SOCIAL_ORGANIC = 1 << 2;
    uint32 constant ONLINE_OWNED_OPERATED = 1 << 3; // cl. 2.5(ii) primary exploitation
    uint32 constant ONLINE_DISPLAY_VIDEO = 1 << 4;
    uint32 constant ONLINE_OTHER_AV = 1 << 5; // "now known or hereafter devised"
    uint32 constant LONG_FORM_VOD = 1 << 6; // explicitly OUT
    uint32 constant OTT = 1 << 7; // explicitly OUT
    uint32 constant IPTV = 1 << 8; // explicitly OUT
    uint32 constant DIGITAL_TV = 1 << 9; // explicitly OUT
    uint32 constant BROADCAST_TV = 1 << 10; // not granted
    uint32 constant BROADCAST_RADIO = 1 << 11; // not granted
    uint32 constant CINEMA = 1 << 12; // not granted
    uint32 constant FILM_FESTIVAL = 1 << 13; // IN (Key Terms (ii))
    uint32 constant INDUSTRIAL = 1 << 14; // IN
    uint32 constant INTERNAL = 1 << 15; // IN
    uint32 constant EVENTS = 1 << 16; // IN
    uint32 constant AWARDS_SHOWS = 1 << 17; // IN
    uint32 constant PRESENTATIONS = 1 << 18; // IN
    uint32 constant OUT_OF_HOME = 1 << 19; // not granted
    uint32 constant GAMING = 1 << 20; // not granted

    /// @dev Exactly the media this agreement grants. Anything else is reserved (cl. 3.1).
    uint32 constant THIS_AGREEMENT = ONLINE_SHORT_FORM_VOD | ONLINE_SOCIAL_PAID | ONLINE_SOCIAL_ORGANIC
        | ONLINE_OWNED_OPERATED | ONLINE_DISPLAY_VIDEO | ONLINE_OTHER_AV | FILM_FESTIVAL | INDUSTRIAL | INTERNAL
        | EVENTS | AWARDS_SHOWS | PRESENTATIONS;
}

enum Exclusivity {
    NON_EXCLUSIVE, // this agreement
    CATEGORY_EXCLUSIVE,
    FULLY_EXCLUSIVE
}

/// @dev cl. 6.3 — which observable event bound the Licensee.
enum BindingTrigger {
    WRITTEN_ACCEPTANCE,
    PAYMENT,
    FIRST_SYNC,
    DOWNLOAD,
    COUNTERSIGNATURE
}

/// @dev Key Terms vs cl. 2.1 give different rules. Record which one the parties settle on.
enum PaymentRule {
    DAYS_AFTER_INVOICE,
    END_OF_MONTH_FOLLOWING
}

enum InstalmentState {
    SCHEDULED,
    INVOICED,
    PAID,
    OVERDUE,
    CANCELLED
}

enum ProposalState {
    DRAFT,
    PROPOSED,
    COUNTERED,
    ACCEPTED,
    REJECTED,
    WITHDRAWN,
    LAPSED
}

/// @dev See §8.2. There is deliberately no SUSPENDED_FOR_BREACH state (cl. 5.5).
enum LicenceState {
    ISSUED,
    ACTIVE,
    PAYMENT_HOLD,
    NOTICE_GIVEN,
    TERMINATED,
    EXPIRED,
    RESCINDED,
    LAPSED
}

/// @dev cl. 5.5 — the only grounds on which the Licensor may rescind.
enum RescissionGround {
    NON_PAYMENT,
    BREACH_CL_2_3,
    BREACH_CL_7,
    BREACH_CL_8_SIC // OPEN-Q6: stale cross-reference; rescind() rejects this ground until resolved
}

/// @dev cl. 3.1 — what the declarer asserts at the moment of use. Cheap to record, and a
///      false assertion is timestamped evidence for a cl. 5.5 damages claim. Bitmask.
library Attestation {
    uint8 constant NOT_TITLE_OR_STORYLINE = 1 << 0; // 3.1(iii) — required on every declaration
    uint8 constant IN_CONTEXT_ONLY = 1 << 1; // 3.1(iv)  — required on every declaration
    uint8 constant TITLE_USE_CONFIRMED = 1 << 2; // 3.1(iii) — required only when TitleUseFlagged
    uint8 constant NOT_AUDIO_ONLY = 1 << 3; // 3.1(ii)
    uint8 constant CHARACTER_UNALTERED = 1 << 4; // 3.1(vi)
    uint8 constant REQUIRED_BASE = NOT_TITLE_OR_STORYLINE | IN_CONTEXT_ONLY | NOT_AUDIO_ONLY | CHARACTER_UNALTERED;
}

// ---------------------------------------------------------------------------
// §4.2 Territory
// ---------------------------------------------------------------------------

struct Territory {
    bool worldwide; // this agreement: true for both
    bytes2[] included; // ISO 3166-1 alpha-2, sorted, ignored if worldwide
    bytes2[] excluded; // carve-outs from worldwide
}

// ---------------------------------------------------------------------------
// §4.3 Licence terms (the Key Terms, encoded)
// ---------------------------------------------------------------------------

struct LicenceTerms {
    // ---- scope ----------------------------------------------------------------
    LicenceScope scope; // CATALOGUE
    bytes32 catalogueId; // RightsRegistry catalogue key (scope == CATALOGUE)
    bytes32 trackId; // RightsRegistry track key (scope == TRACK)
    uint8 rightsMask; // Rights.MASTER | Rights.COMPOSITION
    uint16 contentMask; // Content.*
    uint32 mediaMask; // Media.*  — THIS_AGREEMENT
    Exclusivity exclusivity; // NON_EXCLUSIVE
    bool irrevocable; // true (cl. 2.1)
    // ---- territories (three, not one) ------------------------------------------
    Territory syncTerritory; // where Productions may be made (cl. 2.2)
    Territory distributionTerritory; // where Productions may be exploited (cl. 2.1)
    Territory editTerritory; // cl. 2.3 "Territory" — undefined; OPEN-Q1 default = syncTerritory
    // ---- clocks (two, not one) --------------------------------------------------
    uint64 effectiveFrom; // 2024-04-12 — retrospective (Key Terms)
    uint64 executedAt; // 2024-06-04
    uint64 syncTermStart; // 2024-04-12
    uint64 syncTermEnd; // 2026-04-11 23:59:59
    bool distributionPerpetual; // true
    uint64 distributionTermEnd; // 0 when perpetual
    // ---- editing and context ----------------------------------------------------
    bool editingPermitted; // true (cl. 2.3)
    bool outOfContextPermitted; // false (cl. 3.1(iv))
    bool titleUsePermitted; // false (cl. 3.1(iii))
    // ---- money ----------------------------------------------------------------
    bytes3 currency; // "GBP"
    PaymentRule paymentRule; // OPEN-Q2 default = DAYS_AFTER_INVOICE
    uint32 dueDaysAfterInvoice; // 60
    bool refundsPermitted; // false (cl. 6.2)
    // ---- lifecycle ------------------------------------------------------------
    uint32 licenseeNoticeDays; // 30 (cl. 9.1)
    bool licensorMayTerminate; // false — no such right exists
    bytes32 affiliateGroupId; // cl. 7 free-assignment group (name redacted)
    // ---- legal anchors --------------------------------------------------------
    bytes32 termsHash; // keccak256 of the executed document
    string termsURI; // encrypted pointer
    bytes32 hcsTopicId; // negotiation trail (NOT part of the agreement — cl. 6.1)
    bytes2 governingLaw; // "GB" (England & Wales)
    uint64 proposalExpiry; // offer lapses → LAPSED
}

// ---------------------------------------------------------------------------
// §4.4 Fee schedule
// ---------------------------------------------------------------------------

/// @dev One of the two annual instalments. Amounts redacted in source.
///      `amountCommitment` is the one extension to §4.4: it carries keccak256(abi.encode(index,
///      amountMinor, salt)) so the plan can be recorded with `amountMinor == 0` while §10 Q10
///      (may fee amounts be public?) is open — invariant I20.
struct FeeInstalment {
    uint8 index; // 1, 2
    uint256 amountMinor; // GBP pence, ex-tax (0 while undisclosed — OPEN-Q10)
    bytes32 amountCommitment; // OPEN-Q10 hash commitment to the amount
    uint64 scheduledFor; // Year 1: on execution; Year 2: 2025-04-12 (OPEN-Q8)
    uint64 invoicedAt; // 0 until Licensor issues a valid invoice
    uint64 dueAt; // invoicedAt + 60d (or end-of-following-month)
    uint64 paidAt; // 0 until settled
    bytes32 settlementRef; // bank ref hash or on-chain tx
    bool settledOnChain; // false = fiat, attested by PHARE settlement role
    InstalmentState state;
}

// ---------------------------------------------------------------------------
// §4.5 Split sets
// ---------------------------------------------------------------------------

struct SplitEntry {
    address payee;
    uint16 bps;
    bytes32 partyId;
    bool confirmed; // cl. 5.1 — collaborator confirmed on-chain
}

struct SplitSet {
    SplitEntry[] entries; // Σ bps == 10_000
    address residualPayee; // absorbs integer-division dust (I6)
    bool locked; // all confirmed
}

/// @dev How a CATALOGUE-scope fee is divided among the tracks actually used. OPEN-Q7.
enum ApportionmentPolicy {
    LIBRARY_RETAINS, // Licensor takes 100%; pays composers off-chain per their own deals
    EQUAL_PER_DECLARATION, // fee ÷ declarations, then each track's SYNC split set
    WEIGHTED_BY_DURATION, // needs off-chain duration data on each declaration
    PRO_RATA_CATALOGUE // every track in the catalogue shares equally, used or not
}

// ---------------------------------------------------------------------------
// §4.6 Licence, declarations, edits, reports
// ---------------------------------------------------------------------------

/// @dev One per ERC-721 tokenId — one per executed agreement.
struct Licence {
    uint256 tokenId;
    address licensor;
    address licensee; // token holder
    LicenceTerms terms;
    LicenceState state;
    BindingTrigger boundBy; // cl. 6.3
    uint64 boundAt;
    uint64 noticeGivenAt; // cl. 9.1; 0 if none
    uint64 terminatedAt;
    uint256 supersededBy; // cl. 6.1 variation → new token; 0 if none
    uint256 renewalOf;
}

/// @dev cl. 2.6 — who may make declarations and own Productions under this licence.
struct AuthorisedParty {
    address party;
    uint8 role; // 1 = agency/contractor, 2 = advertising client, 3 = group company
    bytes32 partyId;
    bool active;
}

/// @dev What the declarer submits. Packed as a struct to keep declareSync under the stack limit.
struct DeclarationInput {
    uint256 licenceId;
    bytes32 trackId; // must be in catalogueId, must be fully registered (5.1)
    bytes32 productionId; // off-chain Production record
    bytes32 productionTitleHash; // keccak256(normalised title) — cl. 3.1(iii) check
    bytes32 derivedFromProductionId; // 0 = original; non-zero = out-of-context (cl. 3.1(iv)) → reverts here
    address productionOwner; // cl. 2.5(i)
    uint16 contentMask; // ⊆ terms.contentMask
    uint32 mediaMask; // ⊆ terms.mediaMask
    uint8 attestations; // Attestation.* — must include REQUIRED_BASE
    bytes32 metadataHash; // duration, placement, cue sheet — off-chain
}

/// @dev The per-Production clearance record. This is what a broadcaster verifies.
///      Immune to licence state once created (cl. 9.2).
struct SyncDeclaration {
    bytes32 declarationId;
    uint256 licenceId;
    bytes32 trackId;
    bytes32 productionId;
    bytes32 productionTitleHash;
    bytes32 derivedFromProductionId; // always 0 under this agreement (I10c)
    address declaredBy; // licensee or AuthorisedParty
    address productionOwner; // cl. 2.5(i)
    uint16 contentMask;
    uint32 mediaMask;
    uint8 attestations; // what the brand asserted — cl. 3.1 evidence
    bool titleUseFlagged; // productionTitleHash == registry.titleHash(trackId)
    uint64 declaredAt; // MUST be within sync term and state ACTIVE
    bytes32 metadataHash;
    bool distributionPerpetual; // copied from terms at declaration; never changes
}

/// @dev cl. 3.1(iv) — a fingerprint match of a licensed track inside an asset that has no
///      declaration. Raised by PHARE's content-protection oracle. Evidence only (cl. 5.5).
struct UndeclaredUse {
    bytes32 trackId;
    bytes32 assetFingerprint; // hash of the matched asset
    uint256 suspectedLicenceId; // 0 if unknown
    uint64 detectedAt;
    bytes32 evidenceHash;
}

/// @dev cl. 2.3 — a derivative work, owned by the Licensor.
struct EditedMaterial {
    bytes32 editId;
    bytes32 declarationId;
    bytes32 parentTrackId;
    address owner; // == licence.licensor, no setter
    bytes32 contentHash;
    uint64 registeredAt;
    bool challenged; // cl. 2.3 proviso disputed
}

/// @dev cl. 4 — a formal report on request. Declarations are the continuous report.
struct UsageReport {
    uint256 licenceId;
    uint64 requestedAt;
    uint64 submittedAt; // 0 = outstanding
    bytes32 reportHash;
    string reportURI;
}

/// @dev cl. 3.1 — evidence only. Changes no state (cl. 5.5).
struct BreachAllegation {
    uint256 licenceId;
    bytes32 declarationId; // 0 if licence-level
    uint8 covenant; // 1..8
    bytes32 evidenceHash;
    uint64 allegedAt;
}
