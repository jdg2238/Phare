// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RightsRegistry} from "../src/RightsRegistry.sol";
import {LicenceNegotiation} from "../src/LicenceNegotiation.sol";
import {SubscriptionLicence721} from "../src/SubscriptionLicence721.sol";
import {FeeSchedule} from "../src/FeeSchedule.sol";
import {RoyaltySplitter} from "../src/RoyaltySplitter.sol";
import {ClearanceLedger} from "../src/ClearanceLedger.sol";
import {IFeePlanValidator} from "../src/interfaces/IFeePlanValidator.sol";

/// @notice Deploys the PHARE sync-licence stack in §11 build order and wires the §6 roles.
/// @dev Environment:
///        PRIVATE_KEY            deployer
///        PHARE_ADMIN            DEFAULT_ADMIN / UPGRADER on every contract (multisig recommended)
///        SETTLEMENT_ATTESTOR    PHARE settlement role (fiat receipts) — multisig
///        RESOLVER               OPEN-Q9 2-of-3 (licensor + licensee + PHARE)
///        ORACLE                 PHARE content-protection service (OPEN-Q13) — evidence only
///        PLATFORM               PHARE platform signer (observes downloads — cl. 6.3)
///      Run: forge script script/Deploy.s.sol --rpc-url $HEDERA_RPC --broadcast
contract Deploy is Script {
    function run() external {
        address admin = vm.envAddress("PHARE_ADMIN");
        address attestor = vm.envAddress("SETTLEMENT_ATTESTOR");
        address resolver = vm.envAddress("RESOLVER");
        address oracle = vm.envAddress("ORACLE");
        address platform = vm.envAddress("PLATFORM");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // 1. RightsRegistry (UUPS)
        RightsRegistry registry = RightsRegistry(
            address(
                new ERC1967Proxy(address(new RightsRegistry()), abi.encodeCall(RightsRegistry.initialize, (deployer)))
            )
        );

        // 4. LicenceNegotiation
        LicenceNegotiation negotiation = new LicenceNegotiation(deployer, registry);

        // 5. SubscriptionLicence721 (UUPS)
        SubscriptionLicence721 licence = SubscriptionLicence721(
            address(
                new ERC1967Proxy(
                    address(new SubscriptionLicence721()),
                    abi.encodeCall(SubscriptionLicence721.initialize, (deployer, negotiation))
                )
            )
        );

        // 3. FeeSchedule, 2. RoyaltySplitter
        FeeSchedule fees = new FeeSchedule(deployer, licence);
        RoyaltySplitter splitter = new RoyaltySplitter(deployer, fees, licence, registry);

        // 6. ClearanceLedger (UUPS)
        ClearanceLedger ledger = ClearanceLedger(
            address(
                new ERC1967Proxy(
                    address(new ClearanceLedger()),
                    abi.encodeCall(ClearanceLedger.initialize, (deployer, licence, registry))
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

        // hand admin to the PHARE multisig and drop the deployer
        _handover(registry, admin, deployer);
        _handover(licence, admin, deployer);
        _handover(ledger, admin, deployer);
        fees.grantRole(fees.DEFAULT_ADMIN_ROLE(), admin);
        fees.renounceRole(fees.DEFAULT_ADMIN_ROLE(), deployer);
        splitter.grantRole(splitter.DEFAULT_ADMIN_ROLE(), admin);
        splitter.renounceRole(splitter.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        console2.log("RightsRegistry        ", address(registry));
        console2.log("LicenceNegotiation    ", address(negotiation));
        console2.log("SubscriptionLicence721", address(licence));
        console2.log("FeeSchedule           ", address(fees));
        console2.log("RoyaltySplitter       ", address(splitter));
        console2.log("ClearanceLedger       ", address(ledger));
    }

    function _handover(RightsRegistry c, address admin, address deployer) private {
        c.grantRole(c.DEFAULT_ADMIN_ROLE(), admin);
        c.grantRole(c.UPGRADER_ROLE(), admin);
        c.grantRole(c.REGISTRAR_ROLE(), admin);
        c.renounceRole(c.REGISTRAR_ROLE(), deployer);
        c.renounceRole(c.UPGRADER_ROLE(), deployer);
        c.renounceRole(c.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _handover(SubscriptionLicence721 c, address admin, address deployer) private {
        c.grantRole(c.DEFAULT_ADMIN_ROLE(), admin);
        c.grantRole(c.UPGRADER_ROLE(), admin);
        c.renounceRole(c.UPGRADER_ROLE(), deployer);
        c.renounceRole(c.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _handover(ClearanceLedger c, address admin, address deployer) private {
        c.grantRole(c.DEFAULT_ADMIN_ROLE(), admin);
        c.grantRole(c.UPGRADER_ROLE(), admin);
        c.renounceRole(c.UPGRADER_ROLE(), deployer);
        c.renounceRole(c.DEFAULT_ADMIN_ROLE(), deployer);
    }
}
