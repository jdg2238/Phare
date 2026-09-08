// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {RightsRegistry} from "../src/RightsRegistry.sol";
import {LicenceNegotiation} from "../src/LicenceNegotiation.sol";
import {SubscriptionLicence721} from "../src/SubscriptionLicence721.sol";
import {FeeSchedule} from "../src/FeeSchedule.sol";
import {RoyaltySplitter} from "../src/RoyaltySplitter.sol";
import {ClearanceLedger} from "../src/ClearanceLedger.sol";
import {IFeePlanValidator} from "../src/interfaces/IFeePlanValidator.sol";
import "../src/Types.sol";

contract MockGBP is ERC20 {
    constructor() ERC20("Mock GBP", "mGBP") {}

    function decimals() public pure override returns (uint8) {
        return 2; // pence — matches amountMinor 1:1
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Deploys the full PHARE stack and encodes "this agreement" (Key Terms, §4.3 / §4.4).
abstract contract BaseTest is Test {
    // ---- the agreement's clocks (UTC) ----------------------------------------
    uint64 internal constant EFFECTIVE_FROM = 1712880000; // 2024-04-12 00:00:00
    uint64 internal constant EXECUTED_AT = 1717459200; // 2024-06-04 00:00:00
    uint64 internal constant SYNC_TERM_END = 1775951999; // 2026-04-11 23:59:59
    uint64 internal constant YEAR2_SCHEDULED = EFFECTIVE_FROM + 365 days; // OPEN-Q8
    uint64 internal constant T_2025_03_01 = 1740787200;
    uint64 internal constant T_2031_01_01 = 1924992000;

    uint256 internal constant YEAR1_AMOUNT = 1_000_000; // £10,000.00 in pence (placeholder — redacted)
    uint256 internal constant YEAR2_AMOUNT = 1_234_567; // odd number so integer-division dust is exercised
    bytes32 internal constant SALT1 = keccak256("salt-1");
    bytes32 internal constant SALT2 = keccak256("salt-2");

    // ---- actors ------------------------------------------------------------------
    address internal admin = makeAddr("phare-admin");
    address internal licensor = makeAddr("licensor-library");
    address internal licensee = makeAddr("licensee-brand");
    address internal agency = makeAddr("agency"); // role 1
    address internal client = makeAddr("advertising-client"); // role 2
    address internal groupCo = makeAddr("group-company"); // role 3
    address internal affiliate = makeAddr("affiliate");
    address internal composerA = makeAddr("composer-a");
    address internal composerB = makeAddr("composer-b");
    address internal attestor = makeAddr("settlement-attestor");
    address internal resolver = makeAddr("resolver-multisig");
    address internal oracle = makeAddr("content-oracle");
    address internal platform = makeAddr("phare-platform");
    address internal stranger = makeAddr("stranger");

    // ---- ids ---------------------------------------------------------------------
    bytes32 internal constant CATALOGUE = keccak256("production-music-library");
    bytes32 internal constant TRACK1 = keccak256("track-1");
    bytes32 internal constant TRACK2 = keccak256("track-2");
    bytes32 internal constant TRACK3 = keccak256("track-3");
    bytes32 internal constant TRACK_UNCONFIRMED = keccak256("track-unconfirmed"); // in catalogue, splits not locked
    bytes32 internal constant TRACK_OUTSIDE = keccak256("track-outside"); // fully registered, not in catalogue
    bytes32 internal constant TITLE1 = keccak256("home");
    bytes32 internal constant PRODUCTION1 = keccak256("production-1");
    bytes32 internal constant PRODUCTION2 = keccak256("production-2");
    bytes32 internal constant TERMS_HASH = keccak256("executed-agreement.docx");
    bytes32 internal constant HCS_TOPIC = keccak256("0.0.12345");

    // ---- contracts ---------------------------------------------------------------
    RightsRegistry internal registry;
    LicenceNegotiation internal negotiation;
    SubscriptionLicence721 internal licence;
    FeeSchedule internal fees;
    RoyaltySplitter internal splitter;
    ClearanceLedger internal ledger;
    MockGBP internal gbp;

    function setUp() public virtual {
        vm.warp(EXECUTED_AT);
        _deploy();
        _seedRegistry();
    }

    // =========================================================================
    // Deployment (mirrors script/Deploy.s.sol)
    // =========================================================================

    function _deploy() internal {
        vm.startPrank(admin);

        RightsRegistry registryImpl = new RightsRegistry();
        registry = RightsRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(RightsRegistry.initialize, (admin))))
        );

        negotiation = new LicenceNegotiation(admin, registry);

        SubscriptionLicence721 licenceImpl = new SubscriptionLicence721();
        licence = SubscriptionLicence721(
            address(
                new ERC1967Proxy(
                    address(licenceImpl), abi.encodeCall(SubscriptionLicence721.initialize, (admin, negotiation))
                )
            )
        );

        fees = new FeeSchedule(admin, licence);
        splitter = new RoyaltySplitter(admin, fees, licence, registry);

        ClearanceLedger ledgerImpl = new ClearanceLedger();
        ledger = ClearanceLedger(
            address(
                new ERC1967Proxy(
                    address(ledgerImpl), abi.encodeCall(ClearanceLedger.initialize, (admin, licence, registry))
                )
            )
        );

        // wiring
        negotiation.setLicenceContract(address(licence));
        negotiation.setFeeValidator(IFeePlanValidator(address(fees)));
        licence.setFeeSchedule(fees);
        fees.setSplitter(splitter);
        splitter.setLedger(ledger);

        // roles (§6)
        registry.grantRole(registry.LEDGER_ROLE(), address(ledger));
        licence.grantRole(licence.LEDGER_ROLE(), address(ledger));
        licence.grantRole(licence.PLATFORM_ROLE(), platform);
        licence.grantRole(licence.RESOLVER_ROLE(), resolver);
        fees.grantRole(fees.SETTLEMENT_ATTESTOR_ROLE(), attestor);
        splitter.grantRole(splitter.SETTLEMENT_ATTESTOR_ROLE(), attestor);
        ledger.grantRole(ledger.ORACLE_ROLE(), oracle);
        ledger.grantRole(ledger.RESOLVER_ROLE(), resolver);

        vm.stopPrank();

        gbp = new MockGBP();
    }

    function _seedRegistry() internal {
        uint8 both = Rights.MASTER | Rights.COMPOSITION;
        vm.startPrank(admin);
        registry.createCatalogue(CATALOGUE, licensor);
        registry.registerTrack(TRACK1, licensor, both, keccak256("ISRC1"), keccak256("ISWC1"), TITLE1);
        registry.registerTrack(TRACK2, licensor, both, keccak256("ISRC2"), keccak256("ISWC2"), keccak256("rise"));
        registry.registerTrack(TRACK3, licensor, both, keccak256("ISRC3"), keccak256("ISWC3"), keccak256("drift"));
        registry.registerTrack(TRACK_UNCONFIRMED, licensor, both, 0, 0, keccak256("pending"));
        registry.registerTrack(TRACK_OUTSIDE, licensor, both, 0, 0, keccak256("outside"));
        vm.stopPrank();

        vm.startPrank(licensor);
        for (uint256 i = 0; i < 5; i++) {
            bytes32 t = [TRACK1, TRACK2, TRACK3, TRACK_UNCONFIRMED, TRACK_OUTSIDE][i];
            registry.confirmOwnership(t);
        }
        registry.addToCatalogue(CATALOGUE, TRACK1);
        registry.addToCatalogue(CATALOGUE, TRACK2);
        registry.addToCatalogue(CATALOGUE, TRACK3);
        registry.addToCatalogue(CATALOGUE, TRACK_UNCONFIRMED);

        // SYNC split sets — licensor 50 / composerA 30 / composerB 20 (odd bps to exercise dust)
        registry.setSplitSet(TRACK1, uint8(IncomeType.SYNC), _split3(5000, 3333, 1667), licensor);
        registry.setSplitSet(TRACK2, uint8(IncomeType.SYNC), _split3(5000, 2500, 2500), licensor);
        registry.setSplitSet(TRACK3, uint8(IncomeType.SYNC), _split3(7000, 1500, 1500), licensor);
        registry.setSplitSet(TRACK_OUTSIDE, uint8(IncomeType.SYNC), _split3(5000, 2500, 2500), licensor);
        registry.setSplitSet(TRACK_UNCONFIRMED, uint8(IncomeType.SYNC), _split3(5000, 2500, 2500), licensor);
        // a different pot with a different table on TRACK1 (cl. 3.2 / I5)
        SplitEntry[] memory perf = new SplitEntry[](1);
        perf[0] = SplitEntry({payee: composerA, bps: 10_000, partyId: keccak256("A"), confirmed: false});
        registry.setSplitSet(TRACK1, uint8(IncomeType.PUBLISHING_PERFORMANCE), perf, composerA);
        vm.stopPrank();

        // collaborators confirm (cl. 5.1) — except on TRACK_UNCONFIRMED
        bytes32[4] memory confirmed = [TRACK1, TRACK2, TRACK3, TRACK_OUTSIDE];
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(composerA);
            registry.confirmSplit(confirmed[i], uint8(IncomeType.SYNC));
            vm.prank(composerB);
            registry.confirmSplit(confirmed[i], uint8(IncomeType.SYNC));
        }
        vm.prank(composerA);
        registry.confirmSplit(TRACK1, uint8(IncomeType.PUBLISHING_PERFORMANCE));
    }

    function _split3(uint16 a, uint16 b, uint16 c) internal view returns (SplitEntry[] memory s) {
        s = new SplitEntry[](3);
        s[0] = SplitEntry({payee: licensor, bps: a, partyId: keccak256("L"), confirmed: false});
        s[1] = SplitEntry({payee: composerA, bps: b, partyId: keccak256("A"), confirmed: false});
        s[2] = SplitEntry({payee: composerB, bps: c, partyId: keccak256("B"), confirmed: false});
    }

    // =========================================================================
    // "This agreement" — Key Terms encoded (§4.3, §4.4). No invented commercial defaults.
    // =========================================================================

    function worldwide() internal pure returns (Territory memory t) {
        t.worldwide = true;
        t.included = new bytes2[](0);
        t.excluded = new bytes2[](0);
    }

    function agreementTerms() internal view returns (LicenceTerms memory t) {
        t.scope = LicenceScope.CATALOGUE;
        t.catalogueId = CATALOGUE;
        t.trackId = bytes32(0);
        t.rightsMask = Rights.MASTER | Rights.COMPOSITION;
        t.contentMask = Content.THIS_AGREEMENT;
        t.mediaMask = Media.THIS_AGREEMENT;
        t.exclusivity = Exclusivity.NON_EXCLUSIVE;
        t.irrevocable = true;
        t.syncTerritory = worldwide();
        t.distributionTerritory = worldwide();
        t.editTerritory = worldwide(); // OPEN-Q1 default = syncTerritory
        t.effectiveFrom = EFFECTIVE_FROM;
        t.executedAt = EXECUTED_AT;
        t.syncTermStart = EFFECTIVE_FROM;
        t.syncTermEnd = SYNC_TERM_END;
        t.distributionPerpetual = true;
        t.distributionTermEnd = 0;
        t.editingPermitted = true;
        t.outOfContextPermitted = false;
        t.titleUsePermitted = false;
        t.currency = "GBP";
        t.paymentRule = PaymentRule.DAYS_AFTER_INVOICE; // OPEN-Q2
        t.dueDaysAfterInvoice = 60;
        t.refundsPermitted = false;
        t.licenseeNoticeDays = 30;
        t.licensorMayTerminate = false;
        t.affiliateGroupId = keccak256("affiliate-group-redacted");
        t.termsHash = TERMS_HASH;
        t.termsURI = "ipfs://encrypted-terms";
        t.hcsTopicId = HCS_TOPIC;
        t.governingLaw = "GB";
        t.proposalExpiry = uint64(vm.getBlockTimestamp() + 30 days);
    }

    function commitment(uint8 index, uint256 amount, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(index, amount, salt));
    }

    /// @dev Two annual instalments, amounts hash-committed (OPEN-Q10 / I20).
    function agreementFees() internal pure returns (FeeInstalment[] memory f) {
        f = new FeeInstalment[](2);
        f[0] = _instalment(1, 0, commitment(1, YEAR1_AMOUNT, SALT1), EXECUTED_AT);
        f[1] = _instalment(2, 0, commitment(2, YEAR2_AMOUNT, SALT2), YEAR2_SCHEDULED);
    }

    function _instalment(uint8 index, uint256 amount, bytes32 commit, uint64 scheduledFor)
        internal
        pure
        returns (FeeInstalment memory)
    {
        return FeeInstalment({
            index: index,
            amountMinor: amount,
            amountCommitment: commit,
            scheduledFor: scheduledFor,
            invoicedAt: 0,
            dueAt: 0,
            paidAt: 0,
            settlementRef: bytes32(0),
            settledOnChain: false,
            state: InstalmentState.SCHEDULED
        });
    }

    // =========================================================================
    // Flow helpers
    // =========================================================================

    function proposeAndAccept() internal returns (uint256 proposalId) {
        return proposeAndAccept(agreementTerms(), agreementFees());
    }

    function proposeAndAccept(LicenceTerms memory t, FeeInstalment[] memory f) internal returns (uint256 proposalId) {
        vm.prank(licensee);
        proposalId = negotiation.propose(t, f);
        vm.prank(licensor);
        negotiation.accept(proposalId);
    }

    /// @dev Brand accepts in writing → token minted and ACTIVE.
    function mintActive() internal returns (uint256 tokenId) {
        uint256 pid = proposeAndAccept();
        vm.prank(licensee);
        tokenId = licence.mintFromProposal(pid, uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
    }

    function mintActive(LicenceTerms memory t) internal returns (uint256 tokenId) {
        uint256 pid = proposeAndAccept(t, agreementFees());
        vm.prank(licensee);
        tokenId = licence.mintFromProposal(pid, uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
    }

    function declarationInput(uint256 tokenId, bytes32 trackId, bytes32 productionId)
        internal
        view
        returns (DeclarationInput memory d)
    {
        d.licenceId = tokenId;
        d.trackId = trackId;
        d.productionId = productionId;
        d.productionTitleHash = keccak256("summer campaign 2025");
        d.derivedFromProductionId = bytes32(0);
        d.productionOwner = licensee;
        d.contentMask = Content.ADVERTISING_PAID;
        d.mediaMask = Media.ONLINE_SHORT_FORM_VOD | Media.ONLINE_SOCIAL_PAID;
        d.attestations = Attestation.REQUIRED_BASE;
        d.metadataHash = keccak256("cue-sheet");
    }

    function declare(uint256 tokenId, bytes32 trackId, bytes32 productionId) internal returns (bytes32) {
        vm.prank(licensee);
        return ledger.declareSync(declarationInput(tokenId, trackId, productionId));
    }

    function disclose(uint256 tokenId) internal {
        vm.startPrank(licensor);
        fees.discloseAmount(tokenId, 1, YEAR1_AMOUNT, SALT1);
        fees.discloseAmount(tokenId, 2, YEAR2_AMOUNT, SALT2);
        vm.stopPrank();
    }

    function invoiceAndAttest(uint256 tokenId, uint8 index) internal {
        vm.prank(licensor);
        fees.markInvoiced(tokenId, index, keccak256(abi.encode("invoice", index)));
        vm.prank(attestor);
        fees.attestFiatSettlement(tokenId, index, keccak256(abi.encode("bank-ref", index)));
    }

    function stateOf(uint256 tokenId) internal view returns (LicenceState) {
        return LicenceState(licence.state(tokenId));
    }
}
