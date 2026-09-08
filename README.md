# PHARE — Sync Licence Smart Contracts

Solidity implementation of the PHARE sync-licence schema described in
**PHARE Sync Licence — Contract Map & Implementation Schema v1.1** (`PHAREsynclicencespec.md`).
Target: Hedera EVM · Solidity 0.8.30 · Foundry · OpenZeppelin 5.6.1.

The spec models a real, executed agreement: a **two-year blanket subscription to a production-music
library** (master and composition rights), for online advertising and corporate content, worldwide,
paid in two annual instalments against invoice. The contracts implement §7 (interfaces) and §8 (state
machines) of that document; every invariant in §9 has a test; every §10 open question is implemented
with the spec's stated default and marked `OPEN-Q<n>` in the code.

## What the contracts do, in plain terms

| Contract | Role in the business | Spec clauses |
| --- | --- | --- |
| `RightsRegistry` | The library's catalogue: which tracks exist, who owns them, how sync income is split, and whether every collaborator has confirmed their share. A track can only be used under a licence once it is *fully registered* — that is how the Licensor's ownership warranty (cl. 5.1) becomes checkable per track. Also records edited versions, which belong to the library (cl. 2.3). | KT, 2.3, 3.2, 5.1 |
| `LicenceNegotiation` | Offer / counter-offer / accept between brand and library. Only the outcome is stored; the message trail lives on a Hedera Consensus Service topic and is *not* part of the agreement (cl. 6.1). | 2.1, 6.1 |
| `SubscriptionLicence721` | One ERC-721 token per signed agreement. Holds the Key Terms (immutable), the licence lifecycle, who else may act for the brand (agencies, clients, group companies), the assignment rules, the brand's exit on notice, and the very narrow rescission path. There is deliberately **no** "suspend" or "terminate" button for the library (cl. 5.5, cl. 9). | 2.1, 2.5, 2.6, 6.3, 7, 9 |
| `ClearanceLedger` | The public record a broadcaster or platform checks: one clearance record per Production. Once made, a record stays valid forever regardless of what later happens to the subscription (cl. 9.2). Also holds edits, usage reports, and breach *evidence* (which changes no state). | 2.2, 2.3, 3.1, 4, 5.1, 9.2 |
| `FeeSchedule` | The two instalments: invoice → due → paid. Fiat settlement attested by PHARE is the primary path; HBAR / ERC-20 settlement also exists. Nothing is ever refunded, reduced or cancelled (cl. 2.4, 6.2). An instalment 30 days past due puts *new* syncs on hold; existing clearances are untouched. | 2.1, 2.4, 6.2 |
| `RoyaltySplitter` | Divides each settled instalment among the artists whose tracks were used, using one of four selectable apportionment policies, then each track's SYNC split table. Every unit is accounted for; rounding dust goes to a named residual payee. Never touches performance-royalty pots (cl. 3.2). | 3.2, 4 |

`RightsRegistry`, `SubscriptionLicence721` and `ClearanceLedger` are UUPS-upgradeable proxies (§6).

## The one behaviour that matters most

**A clearance never expires.** A declaration made in 2025 under a licence that ended in April 2026 still
verifies true in 2031 (`test_2031BroadcasterCheck`). The sync right — the right to make *new* Productions —
ends with the term or with the brand's notice; the right to keep distributing what was already made is
perpetual. `verifyClearance` therefore never reads the licence state at all.

## Repository layout

```
src/
  Types.sol                    §4 data model: enums, bitmasks, structs (one field added — see OPEN-Q10)
  interfaces/                  §7 interfaces, verbatim, plus IFeePlanValidator
  libraries/TerritoryLib.sol   ISO 3166-1 alpha-2 membership (worldwide with carve-outs, or a list)
  libraries/DateTime.sol       "end of the month following" due-date arithmetic (cl. 2.1)
  RightsRegistry.sol           §11 step 1
  RoyaltySplitter.sol          §11 step 2
  FeeSchedule.sol              §11 step 3
  LicenceNegotiation.sol       §11 step 4
  SubscriptionLicence721.sol   §11 step 5
  ClearanceLedger.sol          §11 step 6
test/
  BaseTest.sol                 deploys the full stack behind proxies; encodes "this agreement"
  *.t.sol                      one suite per contract, test names carry the invariant id (I1 … I20)
  Integration.t.sol            §11 step 7 — the 2031 broadcaster check and a full lifecycle
script/Deploy.s.sol            build-order deployment with role wiring and admin hand-over
```

## Invariant coverage (§9)

| Invariant | Test |
| --- | --- |
| I1, I1b, I1c | `FeeScheduleTest.test_I1_*` |
| I2, I3 | `ClearanceLedgerTest.test_I2_*`, `test_I3_*` |
| I4 | `RightsRegistryTest.test_I4_*` (incl. fuzz) |
| I5, I6 | `RoyaltySplitterTest.test_I5_*`, `test_I6_*` / `testFuzz_I6_*` |
| I7, I7b | `SubscriptionLicence721Test.test_I7_*`, `test_I7b_*` |
| I8, I9 | `ClearanceLedgerTest.test_I8_*`, `test_I9_*`; `RightsRegistryTest.test_I8_*` |
| I10, I10b–I10f | `ClearanceLedgerTest.test_I10*` |
| I11 | `SubscriptionLicence721Test.test_I11_*` |
| I12 | `ClearanceLedgerTest.test_I12_*` (TERMINATED, EXPIRED, RESCINDED) |
| I13 | `ClearanceLedgerTest.test_I13_*` |
| I14 | `ClearanceLedgerTest.test_I14_*` |
| I15–I18 | `SubscriptionLicence721Test.test_I15_*` … `test_I18_*` |
| I19 | `LicenceNegotiationTest.test_I19_*` |
| I20 | `FeeScheduleTest.test_I20_*` |
| §11 step 7 | `IntegrationTest.test_2031BroadcasterCheck` |

## Open questions (§10) — defaults implemented, tagged `OPEN-Q<n>` in code

| # | Default in code | Where |
| --- | --- | --- |
| Q1 | `editTerritory` kept as a separate field; the test fixture sets it equal to `syncTerritory` | `Types.sol` |
| Q2 | `PaymentRule.DAYS_AFTER_INVOICE`, 60 days. `END_OF_MONTH_FOLLOWING` is also implemented | `FeeSchedule.markInvoiced` |
| Q3 | Overdue instalment → after a 30-day grace, `PAYMENT_HOLD`: no *new* declarations; existing clearances unaffected; cleared on payment | `FeeSchedule.markOverdue`, `SubscriptionLicence721.canDeclare` |
| Q4 | Year-2 instalment **stays payable** after a cl. 9.1 termination. No cancel path exists | `FeeSchedule` (absence of any cancel/refund function) |
| Q5 | 3.1(iii)/(iv) enforced for every licence via `titleUsePermitted` / `outOfContextPermitted`; set both `true` on a token if lawyers conclude the blank covenants do not bind | `ClearanceLedger.declareSync` |
| Q6 | `BREACH_CL_8_SIC` exists in the enum but `rescind` **rejects** it | `SubscriptionLicence721.rescind` |
| Q7 | All four `ApportionmentPolicy` values implemented and selectable per instalment by the licensor (or PHARE's settlement role). `LIBRARY_RETAINS` is the stated default for this Licensor | `RoyaltySplitter.distributeInstalment` |
| Q8 | Year-2 `scheduledFor = syncTermStart + 365 days`; `dueAt` still computed from the actual invoice date | test fixture / `FeeSchedule` |
| Q9 | `RESOLVER_ROLE` (intended: 2-of-3 multisig). Rescission is prospective only: existing declarations keep verifying | `SubscriptionLicence721.rescind`, `test_I12_clearanceSurvivesRescission_prospectiveOnly` |
| Q10 | Fee amounts are **hash-committed**, not stored in plaintext, until the admin flips `feeAmountsDisclosed`. Either party can reveal an amount against its commitment. Party identities are addresses + `partyId` hashes only | `FeeSchedule.validatePlan`, `discloseAmount` |
| Q11 | `hcsTopicId` is stored on the token and never read by contract logic | `LicenceNegotiation` |
| Q12 | A cut-down is a new asset: it must be declared with `derivedFromProductionId`, which reverts under this agreement | `ClearanceLedger.declareSync` |
| Q13 | `ORACLE_ROLE` can only ever write evidence (`reportUndeclaredUse`); the Licensor must still `allegeBreach` | `ClearanceLedger` |

## Design decisions beyond the letter of the spec

These are engineering choices the spec leaves open. Each is small and reversible; flag any you disagree with.

- **`FeeInstalment.amountCommitment`** (one added field) — the mechanism that lets I20 hold: `keccak256(abi.encode(index, amountMinor, salt))`. With amounts undisclosed, an on-chain distribution reverts `AmountUndisclosed` until a party reveals the amount; fiat instalments can still be attested paid.
- **Binding triggers are role-gated** (cl. 6.3): `WRITTEN_ACCEPTANCE` by the licensee, `PAYMENT` by `FeeSchedule`, `FIRST_SYNC` by `ClearanceLedger`, `DOWNLOAD` by PHARE's `PLATFORM_ROLE`, `COUNTERSIGNATURE` by the licensor. `mintFromProposal` mints and binds in one call; `issue` + `bind` is the two-step path (`ISSUED` → `ACTIVE`).
- **Expiry, lapse and payment hold are computed** in `state()` and persisted lazily by `touch()`. A lapsed `ISSUED` token is burned on touch; its record is kept.
- **Notice during a payment hold** is allowed (the brand always has its cl. 9.1 right), but the hold keeps blocking new declarations until arrears are cleared.
- **Variation (cl. 6.1)** mints the new token bound by `WRITTEN_ACCEPTANCE`, since the accepted variation proposal already carries both parties' consent. The old token's outstanding instalments are not cancelled.
- **Production ownership (cl. 2.5(i))**: an agency (role 1) may declare but may not own the Production; a client (role 2) or group company (role 3) may.
- **One clearance per (licence, track, production)**; a second declaration of the same triple reverts.
- **Apportionment dust**: rounding from dividing the fee across declarations or tracks goes to the licensor; rounding inside a track's split table goes to that table's `residualPayee` (I6).
- **`EQUAL_PER_DECLARATION` with zero declarations reverts** rather than inventing a fallback; the licensor can distribute under `LIBRARY_RETAINS` instead.
- **On-chain settlement compares amounts 1:1 with `amountMinor`**, so the settlement token's minor unit must equal the fee's (e.g. a 2-decimal GBP token).

## Build and test

```bash
forge install            # forge-std, openzeppelin-contracts@v5.6.1, openzeppelin-contracts-upgradeable@v5.6.1
forge build
forge test               # 97 tests, incl. fuzz runs for I4 and I6
forge test --match-test test_2031BroadcasterCheck -vv
```

`foundry.toml` pins `solc 0.8.30`, `evm_version = cancun` (supported on Hedera mainnet since the 0.59
release), `via_ir = true` and `offline = true`. If your environment cannot reach the Solidity binary
host, drop a `solc-static-linux` release binary at `~/.svm/0.8.30/solc-0.8.30`.

## Deploy

```bash
export PRIVATE_KEY=… PHARE_ADMIN=… SETTLEMENT_ATTESTOR=… RESOLVER=… ORACLE=… PLATFORM=…
forge script script/Deploy.s.sol --rpc-url https://testnet.hashio.io/api --broadcast
```

The script deploys in §11 build order, wires the cross-contract roles, then hands every admin and
upgrader role to `PHARE_ADMIN` and renounces the deployer. The attestor and resolver should be multisigs;
the oracle can only write evidence.

## Before this goes to audit

- Re-run the clause mapping against the complete executed agreement; the party names, fee amounts and
  affiliate group are redacted in the source and carried here as hashes and placeholders.
- Close Q4, Q5 and Q7 with counsel; they carry the most commercial weight.
- Decide Q10 (fee confidentiality) — until then leave `feeAmountsDisclosed` off.
