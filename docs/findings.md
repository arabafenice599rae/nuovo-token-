# Triage dei finding — FixedSaleV4

Analisi eseguita su `src/FixedSaleV4.sol` con la toolchain pinnata del repo
(forge 1.8.1 / solc 0.8.26 via-ir, slither 0.11.6, aderyn 0.6.8) contro le
dipendenze in `lib/` (v4-core 59d3ecf, v4-periphery ad04c9f, permit2 cc56ad0,
OpenZeppelin 21c8312).

Stato dei gate dopo il triage: **slither 0 finding >= medium**, **aderyn 0 High**.
Tutto il resto e' riportato qui sotto, non nascosto.

## Soppressioni attive

Ogni soppressione e' puntuale (inline nel sorgente) o motivata a livello di
config. Nessuna modifica alla logica: il bytecode di `FixedSaleV4` compilato con
e senza le righe di commento aggiunte e' **identico** (verificato con
`forge inspect ... bytecode | sha256sum`).

| Finding | Tool | Severita' | Sede | Perche' e' un falso positivo | Dove e' soppresso |
| --- | --- | --- | --- | --- | --- |
| `unchecked-transfer` (x3) | slither | High | `finalize`, `unlockCallback`, `claim` | `token` e' `LaunchToken`, un OZ `ERC20` creato da questo contratto: reverte su fallimento e non ritorna mai `false` | inline `slither-disable-next-line` |
| `incorrect-equality` | slither | Medium | `sweepDust` (`dust == 0`) | uguaglianza stretta su un saldo usata solo per revertire (`NoDust`), non guida nessun calcolo | inline `slither-disable-next-line` |
| `unused-return` (x6) | slither | Medium | `initialize`, `getSlot0` (x3), `settle` (x2) | destrutturazioni parziali di `getSlot0` e valori di ritorno del glue v4 (`initialize` -> tick, `settle` -> importo pagato). I delta sono comunque verificati dal PoolManager alla chiusura dell'unlock | `detectors_to_exclude` in `slither.config.json` |
| `unsafe-casting` (x2) | aderyn | High | `finalize`, parametri di `MINT_POSITION` (`uint128(ethAvail)`, `uint128(tokenAvail)`) | `tokenAvail <= MAX_TOTAL_SUPPLY` (1e27) e `ethAvail <= ETH raccolto`: entrambi ordini di grandezza sotto 2^128 (~3.4e38) | inline `aderyn-fp-next-line` |
| `eth-send-unchecked-address` (x5) | aderyn | High | `buy`, `finalize`, `refund`, `withdrawFees`, `sweepDust` | i destinatari sono `msg.sender` (pull) o `feeRecipient`, immutabile e validato `!= address(0)` nel costruttore | `[detectors] exclude` in `aderyn.toml` |
| `reentrancy-state-change` (x5) | aderyn | High | costruttore, `finalize` | ogni entrypoint esterno e' `nonReentrant` e `finalized` viene scritto prima delle interazioni (CEI) | `[detectors] exclude` in `aderyn.toml` |

Le due esclusioni globali in `aderyn.toml` hanno un costo: **presuppongono che
ogni nuova funzione esterna resti `nonReentrant` e che ogni nuovo destinatario di
ETH sia validato**. Se il contratto cresce, vanno riviste (o convertite in
soppressioni inline).

## Finding aperti (non bloccanti)

Nessuno di questi fa fallire la pipeline; sono elencati perche' restano visibili
a ogni run.

| Finding | Tool | Severita' | Verdetto |
| --- | --- | --- | --- |
| `reentrancy-benign` in `finalize` (`bootstrapTokenId`/`bootstrapLiquidity` scritti dopo `modifyLiquidities`) | slither | Low | accettato: `finalized = true` e' gia' scritto e la funzione e' `nonReentrant` |
| `reentrancy-events` in `unlockCallback` (`Normalized` emesso dopo le call) | slither | Low | accettato: la callback e' raggiungibile solo dal PoolManager dentro l'unlock aperto da `finalize` |
| `timestamp` (x3) in `buy`, `finalize`, `refund` | slither | Low | intrinseco a una vendita a scadenza; le finestre (deadline, `FINALIZE_GRACE` = 3 giorni) sono ordini di grandezza sopra la manipolabilita' di un validatore |
| `low-level-calls` (x5) | slither | Info | necessari: trasferimenti ETH con `call` e controllo esplicito del successo |
| `pragma` / `unspecific-solidity-pragma` | slither / aderyn | Info / Low | `^0.8.26` nel sorgente contro `solc = "0.8.26"` pinnato in `foundry.toml`: la versione effettiva e' fissata dal progetto. Passare a un pragma fisso resta preferibile |
| `unchecked-return`, `unsafe-erc20-operation` | aderyn | Low | stessa causa dei `unchecked-transfer` sopra: `LaunchToken` reverte |
| `push-zero-opcode` | aderyn | Low | il target e' `evm_version = "cancun"`: PUSH0 e' supportato |
| `large-numeric-literal`, `literal-instead-of-constant`, `state-change-without-event` | aderyn | Low | stile |

## forge lint

`forge lint` non blocca la build (`lint_on_build = false`): gira come step
informativo in CI e con `make lint`. Sul contratto produce 53 warning e 25 note,
in larga parte gli stessi pattern gia' triagiati sopra (`unsafe-typecast` x23 sui
cast dei delta v4, `reentrancy-*` x19, `block-timestamp` x4,
`erc20-unchecked-transfer` x3, `unused-return` x3) piu' note di stile
(`screaming-snake-case-immutable`, `low-level-calls`, `multi-contract-file`).

Un caso e' un falso positivo del linter e vale la pena saperlo:
`divide-before-multiply` su `uint256 fee = (spend * FEE_BPS) / BPS` — li' la
moltiplicazione precede gia' la divisione.

Per rendere il linter bloccante bastano due righe in `foundry.toml`
(`lint_on_build = true`) dopo aver triagiato quei warning con
`// forge-lint: disable-next-line(<rule>)`.

## Nota sul sorgente

Sul file sono state fatte due sole modifiche rispetto al sorgente consegnato,
entrambe non semantiche:

1. le righe di commento con i marker di triage (`slither-disable-next-line`,
   `aderyn-fp-next-line`) elencate sopra;
2. `forge fmt` (gate `forge fmt --check` in CI): ordinamento degli import dentro
   i gruppi esistenti, spaziatura, `(bool ok,)`, collasso di alcune chiamate
   multi-riga, `1_000` -> `1000`.

Il bytecode di `FixedSaleV4` e' identico prima e dopo entrambe
(`d0bd17efe9b55de3950148518a2aaba8ea50b57a08fea29aac778f7f65fd7db8`). Per
tenere la formattazione originale basta togliere lo step `forge fmt --check`
dalla CI.

## Limiti di questa analisi

- L'analisi statica non verifica le invarianti I1-I13 dichiarate nell'header del
  contratto: sono proprieta' di logica economica e di sequenza, fuori dalla
  portata di slither e aderyn. Per quelle c'e' la suite descritta in
  [testing.md](testing.md) (I1-I5, I9, I12 come invarianti con handler; I7/I8 e
  I11 come test di percorso; I13 ancora scoperta).
- La suite di integrazione REV7 citata nell'header del contratto non e' mai
  stata consegnata in questo repo: i test presenti sono stati scritti da zero.
- Il codice upstream in `lib/` e' escluso dall'analisi per scelta
  (`filter_paths`, `exclude`): si analizza il glue code, non le dipendenze.
