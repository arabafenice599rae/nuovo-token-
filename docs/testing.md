# Test

```bash
make test            # tutta la suite (profilo default)
make invariant       # solo le invarianti
make coverage        # forge coverage --report summary
make snapshot        # aggiorna .gas-snapshot
make test-nightly    # profilo ci: fuzz 20k run
```

## Cosa c'e' nel repo

| File | Contenuto |
| --- | --- |
| `test/utils/SaleFixture.sol` | fixture condiviso: PoolManager e PositionManager **reali** (nessun mock), permit2 etchato dal bytecode precompilato, WETH solmate |
| `test/FixedSaleV4.t.sol` | 12 test di percorso: lifecycle sold-out, refund sotto soft cap, refund post-grace (I11), surplus del buy, normalizzazione dopo free-move (H-1), traversata di liquidita' ostile (T3), raccolta fee senza toccare il principal (I9/T6), guardie di costruttore e ingressi, `testFuzz_buyAccounting` |
| `test/Invariants.t.sol` | handler della macchina a stati (buy / refund / claim / finalize / withdrawFees / sweepDust / warp) + invarianti I1-I5, I9, I12 |
| `test/Dependencies.t.sol` | smoke test dei remapping verso `lib/` |

Le invarianti girano di default a **1000 run x depth 150** (150.000 chiamate,
~49 s).

## Copertura delle invarianti dichiarate

| Invariante | Come e' verificata |
| --- | --- |
| I1 solvibilita' ETH | `invariant_I1_ethSolvency` |
| I2 escrow token | `invariant_I2_tokenEscrow` (con ghost sulla somma dei `purchased`) |
| I3 `totalSold <= saleSupply` | `invariant_I3_soldWithinSupply` |
| I4 soft cap al finalize | `invariant_I4_softCapAtFinalize` (ghost del `totalSold` al finalize) |
| I5 contabilita' ETH | `invariant_I5_ethAccounting` — **solo pre-finalize**, vedi nota sotto |
| I6 token in LP <= riserva | indiretta: `test_soldOutLifecycle` e I12 |
| I7 / I8 prezzo e tick al target | asserite dal contratto stesso (revert) ed esercitate da `test_finalizeNormalizesAfterFreeMove` e `test_finalizeCrossesHostileLiquidity` |
| I9 posizione mai ridotta | `invariant_I9_bootstrapPositionUntouched` + `test_collectPoolFeesLeavesPrincipalUntouched` |
| I10 controparti immutabili | `test_constructorRejectsManagerMismatch` |
| I11 liveness | `test_refundBelowSoftCap`, `test_refundAfterGraceAboveSoftCap` |
| I12 conservazione della supply | `invariant_I12_supplyConservation` |
| I13 tick insaturabili | **non verificata qui**: e' una proprieta' statica, servirebbe un test dedicato con `SqrtPriceMath` |

Le invarianti I9 e I12 valgono solo dopo il finalize, quindi
`test_handlerReachesEveryPhase` e `test_handlerReachesRefund` dimostrano che
l'handler raggiunge davvero quegli stati: senza questa guardia le due invarianti
passerebbero a vuoto.

## Copertura

`forge coverage --report summary` su `src/FixedSaleV4.sol`:

| Metrica | Valore |
| --- | --- |
| Righe | 97,50% (156/160) |
| Statement | 90,99% (212/233) |
| Branch | 63,04% (29/46) |
| Funzioni | 100% (13/13) |

I branch mancanti sono in gran parte rami di revert e combinazioni di segno dei
delta nella normalizzazione (`d0 > 0` con `d1 > 0` e simili) che richiedono
configurazioni di liquidita' ostile piu' articolate di quella testata.

## Osservazioni emerse dai test

Nessuna di queste e' un bug; sono comportamenti da conoscere.

1. **`ethForLiquidity` non viene azzerato al finalize.** Resta al valore
   pre-migrazione, quindi dopo il finalize il getter pubblico non descrive piu'
   nulla di reale (i fondi sono nella LP). Per questo I5 e' asserita solo prima
   del finalize.
2. **`onERC721Received` non viene mai invocato.** Il PositionManager minta con
   `_mint`, non `safeMint`: l'hook e' codice difensivo mai raggiunto in
   produzione. E' comunque testato direttamente.
3. **Il dust ETH dopo il mint e' piccolo ma non nullo.** Nel test sold-out (900
   ETH di budget LP) restano ~0,09 ETH, spazzati a `feeRecipient` dentro
   `finalize()`.

## Cosa manca

La suite di integrazione **REV7.t.sol citata nell'header del contratto non e' mai
stata consegnata in questo repo**: i test qui presenti sono stati scritti da
zero. Se la porti, i due file convivono senza conflitti (nomi di contratto
diversi); il fixture in `test/utils/SaleFixture.sol` e' riusabile.
