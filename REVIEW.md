# Notes for the Programmable review

Un1corn (UN1) is a Custom Launch on Ethereum Mainnet (profile 3.6.0) with a Uniswap v4 pool quoted in **UNI**
(`0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984`) and a project hook. This page maps the review topics to code and tests in
this commit. Every test runs with `forge test -j 1` (the fork tests with `ETH_RPC_URL` set); the raw outputs are in
`reports/`.

## Infrastructure deployed before the launch

Deployed through the deterministic CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C` by the launch wallet
`0x722FEad20748DEdB2AB2AE22DfCe77971B394043`. The token and the hook check at initialization that the beacon is bound to
this token; `launch-build/infrastructure.json` has the init and runtime code hashes.

| Contract | Address | Transaction |
|---|---|---|
| UN1MasksData | `0x2f9A3fD93E36809bAFD847A29b5E6C0DBdeA4B4A` | `0x67082b6fd14aa4c0f6a9441fd62e44ef41e345a58cc9c59ebbdc903c5a856003` |
| UN1PartsData | `0x94b5de3277b44959B2e5A9F0dD834209203b95D2` | `0xc186c9651e8f0b676600566fa63429abf8cfd92808192732d1065eeac0fc6439` |
| UN1Renderer | `0xFe7a28d87Aae6a519d1f52960CE8744bD408361F` | `0xfcef653b04f9cd0a9e10e4ad2fa40938872f66748fa6c1b770cbd3408015acbe` |
| UN1Beacon | `0xe9A1C3c7455bC9B2d706FA68e511080863C58937` (bound to the predicted token `0x5B1f03F12172F1953f69AA8a3Cbba99aaff02676`) | `0xc8684d9aa343460aa534e77d88c75127f7700d0f338de778e52f1a9d7defcd00` |

## Launch protection v1 on a UNI-quoted pool

The reference package supports native-quoted pools only; it notes that custom quote assets need a separately verified
replacement. UN1 implements every rule of the published policy (`/v1/launch-protection`) in its own contracts:

| Rule | Implementation | Tests |
|---|---|---|
| 300 seconds from pool creation | `UN1Hook.PROTECTION`; the hook starts `UN1Token.protectedUntil` in `beforeInitialize` | `LaunchProtection.t.sol` |
| Buys only through the canonical Universal Router, which names the buyer | `UN1Hook._buyer`: sender must be `ROUTER` (`0xd92A…446C`) with the code hash recorded at deployment (`routerCodeHash`, declared as a bytes32 literal); buyer = `msgSender()`; other buys revert `UnsupportedRouter`; sells use any route | `test_buys_onlyThroughTheCanonicalRouter_duringProtection`, `ForkProtection.t.sol` (real router; an older router cannot buy) |
| 2% of the initial supply per authenticated buyer, cumulative | `UN1Hook.BUYER_LIMIT` (200 of 10,000), `boughtDuringProtection` | `test_buyerLimit_isCumulative_andSellsDoNotGiveRoomBack`, fork cap test |
| 2% per recipient, cumulative inflow, from any sender | `UN1Token.WALLET_LIMIT`, `receivedDuringProtection` (PoolManager and self-transfers excluded); transfers or sells give no room back | `test_recipientLimit_*` |
| Total buy fee 99% at the first second, extra falling linearly to zero over 30 seconds | `UN1Hook.OPENING_TOTAL_FEE`, `OPENING_FEE_WINDOW`, `openingFee`, `buyFee` | `test_openingFee_fallsLinearlyFrom99Percent`, `test_openingFee_onExactOutputBuys` |
| The extra opening fee goes only to the platform treasury; normal fees continue | the extra is credited to `owed[PLATFORM_RECIPIENT]` (`0xD885…79da`) and counted in `openingFeesCollected`; the normal fee is split as usual; `collect(recipient)` pays only fixed recipients | `test_openingFee_goesToThePlatform_normalFeeSplitAsUsual` |
| Developer plus up to six exempt wallets, fixed in the constructor, still capped | `UN1Hook` constructor `address[6]` (zero = unused; no duplicates; never the developer, token, PoolManager or router), `exemptWallets()`, `isExempt`; exempt wallets keep both 2% caps; sell fees unchanged | `LaunchBuyAndExemptions.t.sol` (`test_exempt_*`) |
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
including the 0.3% platform share, and no opening fee.

## Platform fee

0.3% (`UN1Hook.PLATFORM_FEE` = 3000 ppm) of the UNI side of every buy and sell in the official pool, the initial buy
included, credited to `0xD88539d3c4C460136a733A3Fd60cf6BF269079da`. No other v4 pool can move UN1 (the token admits
PoolManager transfers only with allowances the official hook grants in the same transaction), so the fee cannot be
bypassed on v4. Tests: `OnlyHook.t.sol` (four directions, other pools rejected), `ReviewFeeOrders.t.sol`.

## Static findings of the preflight

| Finding | Where | Evidence |
|---|---|---|
| External dependency (oracle) | `UN1Seeder` reads Chainlink UNI / USD once, at the launch only | staleness, round and sign checks in `openingFdvUsd`; fork test against the live feed |
| Liquidity lock or custody surfaces | `UN1Seeder` (positions, never removed), `UN1Distributor` (permanent bids below the price from 1/8 of the halving fee; reward claims), `UN1Hook` (fee claims as PoolManager balances, `collect` to fixed recipients) | `Rewards.t.sol`, `ReviewHookAccounting.t.sol`, `ReviewR02SettlementScopes.t.sol` |
| Fee surfaces | fixed constants and a halving schedule that only falls (2.1% halves every 2,100 compositions); no setter, no owner | `Compose.t.sol` (halving), `OnlyHook.t.sol` |

There is no owner, admin key, pause or upgrade path in any contract.
