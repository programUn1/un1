# Notes for the Programmable review

Un1corn (UN1) is a Custom Launch on Ethereum Mainnet (profile 3.6.0) with a Uniswap v4 pool quoted in **UNI**
(`0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984`) and a project hook. This page maps the review topics to code and tests in
this commit. Every test runs with `forge test -j 1` (the fork tests with `ETH_RPC_URL` set); the raw outputs are in
`reports/`.

## Changes after the first review (2026-10-18)

1. **Protection and fees are separate components.** As in launch protection v1, the hook's constructor creates three
   contracts, in this order:

   | CREATE child of the hook | Contract | Role |
   |---|---|---|
   | nonce 1 | `UN1FeeVault` | normal-fee vault: the hook mints each swap's normal fee here as UNI claims (ERC-6909) and records it in four ledgers, each payable only to its recipient: platform 0.3% → the fixed treasury `0xD885…79da`; developer → `devRecipient`; reveal bounty reserve → the beacon; halving fee → the distributor (the last two bound once by the hook's initializer, before the pool exists) |
   | nonce 2 | `UN1ProtectionModule` | protection policy: canonical-router buyer authentication, the opening tax (99% falling to the normal fee over 30 seconds), the developer plus six fixed exempt wallets |
   | nonce 3 | `UN1OpeningTaxVault` | opening-tax vault: one ledger, payable only to the fixed platform treasury |

   The hook keeps no fee claims and has no payout path (`collect`, `owed` and the hook's unlock callback are gone). The
   opening tax never enters the normal-fee vault, so the platform's normal 0.3% and its opening tax are separate
   ledgers with separate claims (`UN1FeeVault.claimPlatform`, `UN1OpeningTaxVault.claim`). Anyone may pay the gas of a
   claim; the UNI always goes to the fixed recipient. Each record checks that the vault's claims back its ledgers. The
   exempt wallets skip only the opening tax and keep both 2% limits. The children's addresses are the hook's immutables,
   declared as literals in the launch config (`launch-build/infrastructure.json` → `hookPrediction.children`).
   Tests: `FeeComponents.t.sol` (8), plus the existing protection, fee and exemption tests reading the vaults.
2. **One consistent source bundle.** Every source file now uses LF line endings, so the bytes in the bundle are the
   bytes in the compiler input (`src/libraries/DrandBeacon.sol` had 3 LF lines among 145 CRLF lines; it is now 7,770
   bytes, SHA-256 `7d0f08f9…2a3d`, as in the Standard JSON).
3. To keep the launch transaction well under the EIP-7825 cap with the three new children, `UN1Mirror` (the ERC-721
   view) is now public infrastructure like the beacon, bound to the predicted token; the token's initializer checks both
   bindings (`BadBeacon`, `BadMirror`). The graph has four targets: token, hook, distributor, seeder.

## Infrastructure deployed before the launch

Deployed through the deterministic CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C` by the launch wallet
`0x722FEad20748DEdB2AB2AE22DfCe77971B394043`. `launch-build/infrastructure.json` has the init and runtime code hashes.

| Contract | Address | Transaction |
|---|---|---|
| UN1MasksData | `0x2f9A3fD93E36809bAFD847A29b5E6C0DBdeA4B4A` | `0x67082b6fd14aa4c0f6a9441fd62e44ef41e345a58cc9c59ebbdc903c5a856003` |
| UN1PartsData | `0x94b5de3277b44959B2e5A9F0dD834209203b95D2` | `0xc186c9651e8f0b676600566fa63429abf8cfd92808192732d1065eeac0fc6439` |
| UN1Renderer | `0xFe7a28d87Aae6a519d1f52960CE8744bD408361F` | `0xfcef653b04f9cd0a9e10e4ad2fa40938872f66748fa6c1b770cbd3408015acbe` |
| UN1Beacon | `0xc3647c83679Ae638f26CadF5f22bac852E611375` (bound to the predicted token) | `0x4caa33057c5178a195daece79483bb39e95c523a6fa681c6c38425f93b06fbc9` |
| UN1Mirror | `0x31Cb0df4a0E312faB5AC80D8d1911Cb0F2489158` (bound to the predicted token) | `0x6075f2242eaf522be0feb21d8139cbc36202a8494e7d69c96b87957115c5ddd9` |

Predicted for this bundle: token `0x3158923E41b6242c772d72eFFF863C508BB14D4c`, hook `0xFA673b06dCde76c255f8Cf10d3dF1C83d52Ce5cC` (applicant salt 14645), and the hook's
children `UN1FeeVault` `0x5DcE9EA8d40A69e264DF12881532E47f1f35C223`, `UN1ProtectionModule` `0x2B5Ac0A8E54295053A9BBCF2920A428c44ecBF03`,
`UN1OpeningTaxVault` `0x2d1bC455Fad78bA49b02FAd6869A0891F512D82c`.

The beacon deployed for the first submission (`0xe9A1…8937`) is bound to that bundle's token and is not used.

## Launch protection v1 on a UNI-quoted pool

The reference package supports native-quoted pools only; it notes that custom quote assets need a separately verified
replacement. UN1 implements every rule of the published policy (`/v1/launch-protection`) with the reference layout:

| Rule | Implementation | Tests |
|---|---|---|
| 300 seconds from pool creation | `UN1Hook.PROTECTION`; the hook starts `UN1Token.protectedUntil` in `beforeInitialize` | `LaunchProtection.t.sol` |
| Buys only through the canonical Universal Router, which names the buyer | `UN1ProtectionModule.protectedBuyer`: sender must be `ROUTER` (`0xd92A…446C`) with the code hash recorded when the hook created the module (`routerCodeHash`); buyer = `msgSender()`; other buys revert `UnsupportedRouter`; the launch buy (the pool's first swap) is the developer's; sells use any route | `test_buys_onlyThroughTheCanonicalRouter_duringProtection`, `ForkProtection.t.sol` (real router; an older router cannot buy) |
| 2% of the initial supply per authenticated buyer, cumulative | `UN1Hook.BUYER_LIMIT` (200 of 10,000), `boughtDuringProtection` (in the hook, as in the reference kernel) | `test_buyerLimit_isCumulative_andSellsDoNotGiveRoomBack`, fork cap test |
| 2% per recipient, cumulative inflow, from any sender | `UN1Token.WALLET_LIMIT`, `receivedDuringProtection` (PoolManager and self-transfers excluded); transfers or sells give no room back | `test_recipientLimit_*` |
| Total buy fee 99% at the first second, extra falling linearly to zero over 30 seconds | `UN1ProtectionModule.OPENING_TOTAL_FEE`, `OPENING_FEE_WINDOW`, `openingTax`; `UN1Hook.buyFee` | `test_openingFee_fallsLinearlyFrom99Percent`, `test_openingFee_onExactOutputBuys` |
| The extra opening tax goes only to the platform treasury; normal fees continue | the hook mints the extra to `UN1OpeningTaxVault` (`recordTax`), whose only claim pays `0xD885…79da`; the normal fee goes to `UN1FeeVault` as usual | `test_openingTax_onlyToThePlatformTreasury_separateFromItsNormalFee`, `test_openingFee_goesToThePlatform_normalFeeSplitAsUsual` |
| Developer plus up to six exempt wallets, fixed at deployment, still capped | the hook's `address[6]` constructor argument, checked and kept by `UN1ProtectionModule` (zero = unused; no duplicates; never the developer, hook, token, PoolManager or router), `exemptWallets()`, `isExempt`; exempt wallets keep both 2% caps; sell fees unchanged | `LaunchBuyAndExemptions.t.sol` (`test_exempt_*`), `test_exemptWallets_skipOnlyTheOpeningTax` |
| Minimum starting FDV USD 15,000 against a fixed, fresh feed | `UN1Seeder.openingFdvUsd`: Chainlink UNI / USD `0x5533…220e` (the quote asset's feed), answer within `MAX_FEED_AGE` (1 hour), `MINIMUM_FDV_USD`; else `OpeningValuationTooLow` / `InvalidOraclePrice` | `test_protection_openingValuationFloor`, `test_protection_staleOrBrokenPriceReverts`, `test_fork_protection_openingValuationAgainstChainlink` |
| Atomic initial developer buy with a positive reviewed minimum output | `UN1Seeder.ignite` requires ETH, `buyBps` and `minTokensOut`; the buy runs in the same unlock as pool creation; `minUniOut` and `minTokensOut` bound it | `test_protection_launchBuyIsRequired`, `test_rehearsal_noDevBuy_reverts`, `test_realFactory_launchRevertsWithoutADevBuy` |
| Initial liquidity permanently locked | every position belongs to `UN1Seeder`, which has no remove-liquidity path | `ReviewSeederLocal.t.sol`, `ForkRehearsal.t.sol` |

The rules cannot tell one person's independent wallets apart, as the policy itself notes.

## The initial buy (`INITIAL_BUY_NOT_ESTABLISHED`)

The initial buy is made by `UN1Seeder.ignite`, inside the launch graph and the same PoolManager unlock as pool creation:
the launch ETH buys UNI on the ETH/UNI pool (fee 3000, spacing 60), the UNI buys UN1 as the pool's first swap, and the
tokens go to the developer (`devRecipient`, the launch wallet), as in the protected reference initializer. The submitted
values are 0.05 ETH, `minUniOut` 13.25 UNI and `minTokensOut` 51 UN1 (about 80% of the quote at packing). The first swap
carries the hookData `UN1Hook.LAUNCH_BUY`: the hook then delivers the bought tokens without dealing card slots (a launch
transaction cannot fit them under EIP-7825), and the mark has no effect on any later swap. The swap pays the normal fee,
including the 0.3% platform share, and no opening tax.

## Platform fee

0.3% (`UN1Hook.PLATFORM_FEE` = 3000 ppm) of the UNI side of every buy and sell in the official pool, the initial buy
included, recorded in `UN1FeeVault.platformAccrued` and paid only to `0xD88539d3c4C460136a733A3Fd60cf6BF269079da`
(`claimPlatform`, callable by anyone). No other v4 pool can move UN1 (the token admits PoolManager transfers only with
allowances the official hook grants in the same transaction), so the fee cannot be bypassed on v4. Tests:
`OnlyHook.t.sol` (four directions, other pools rejected), `ReviewFeeOrders.t.sol`, `FeeComponents.t.sol`.

## Launch transaction gas

Real Graph Factory on a mainnet fork, without the router: 14,216,881 – 14,248,038 gas (`ForkRehearsal.t.sol`,
`test_realFactory_launch_*`). The router's own cost in the 28 finalized Ethereum Custom Launches, read with
`debug_traceTransaction` (top-level gas minus the factory frame, intrinsic gas and calldata), was 0.61 – 1.05 million
gas for graphs of 13 – 77 KB; with the largest observed value the launch stays about 1.4 million gas under the
16,777,216 cap.

## Static findings of the preflight

| Finding | Where | Evidence |
|---|---|---|
| External dependency (oracle) | `UN1Seeder` reads Chainlink UNI / USD once, at the launch only | staleness, round and sign checks in `openingFdvUsd`; fork test against the live feed |
| Liquidity lock or custody surfaces | `UN1Seeder` (positions, never removed), `UN1Distributor` (permanent bids below the price from 1/8 of the halving fee; reward claims), `UN1FeeVault` and `UN1OpeningTaxVault` (fee claims as PoolManager balances, paid only to fixed recipients) | `Rewards.t.sol`, `ReviewHookAccounting.t.sol`, `ReviewR02SettlementScopes.t.sol`, `FeeComponents.t.sol` |
| Fee surfaces | fixed constants and a halving schedule that only falls (2.1% halves every 2,100 compositions); no setter, no owner | `Compose.t.sol` (halving), `OnlyHook.t.sol` |

There is no owner, admin key, pause or upgrade path in any contract.
