# Obiettivo del lancio

## In una riga

Vendere una quota fissa di token a prezzo fisso e, appena la vendita chiude con
successo, immettere automaticamente ricavato e riserva in un pool Uniswap v4
allo stesso prezzo, con la posizione di liquidita' trattenuta per sempre dal
contratto e nessuna figura amministrativa che possa intervenire dopo il deploy.

## Il problema

In un lancio di token il rischio non e' il codice del token: e' la finestra fra
la fine della raccolta e la creazione del mercato. In quella finestra, nei
lanci gestiti manualmente, chi ha raccolto i fondi decide da solo quanta
liquidita' immettere, a che prezzo, quando, e se ritirarla il giorno dopo. Le
tre modalita' di fallimento tipiche sono:

1. **liquidita' insufficiente o assente** — il mercato apre sottile e il primo
   ordine muove il prezzo di percentuali a due cifre;
2. **liquidita' ritirabile** — chi controlla la posizione LP puo' rimuoverla e
   uscire con il ricavato (rug pull);
3. **prezzo d'apertura arbitrario** — il pool viene inizializzato a un prezzo
   scollegato da quello pagato dagli acquirenti, o viene manipolato da terzi
   prima che la liquidita' arrivi.

## L'obiettivo

Rendere le tre cose sopra **impossibili per costruzione**, non oggetto di
promesse. In concreto il lancio deve garantire che:

| Obiettivo | Come e' garantito |
| --- | --- |
| Prezzo di vendita noto e invariabile | `pricePerToken` e' `immutable`: fissato al deploy, nessuno lo puo' cambiare |
| Prezzo di apertura del mercato = prezzo di vendita | il pool e' inizializzato nel costruttore al prezzo derivato da `pricePerToken`; prima del mint della posizione il contratto **verifica** che prezzo e tick siano ancora quelli, e altrimenti reverte |
| Liquidita' proporzionale al raccolto | il 90% dell'ETH raccolto e il 90% della supply in vendita finiscono nel pool; il rapporto e' fissato dalle costanti, non da una decisione |
| Liquidita' non ritirabile | l'NFT della posizione resta al contratto: non esiste nessuna funzione di trasferimento, approvazione o rimozione della liquidita' |
| Nessuna allocazione occulta | l'intera supply e' coniata nel costruttore ed e' solo vendita + liquidita'; non esiste una funzione di mint, e i token non venduti vengono **bruciati** |
| Uscita garantita se il lancio fallisce | sotto soft cap alla scadenza, o se la migrazione non avviene entro 3 giorni, ogni acquirente riprende **il 100% dell'ETH versato, fee inclusa** |
| Nessun potere discrezionale | nessun owner, nessun admin, nessuna pausa, nessun upgrade, nessun proxy |

## Come funziona

### Parametri (fissati al deploy, tutti `immutable`)

| Parametro | Significato |
| --- | --- |
| `saleSupply` | token messi in vendita |
| `pricePerToken` | wei per 1e18 unita' di token |
| `saleDuration` | durata della finestra di acquisto |
| `softCapBps` | quota minima di `saleSupply` da vendere perche' il lancio sia valido |
| `feeRecipient` | destinatario della commissione e delle swap fee |

Da questi discendono, senza altre scelte: `liquidityReserve` = 90% di
`saleSupply` (la riserva destinata al pool), la supply totale del token
(`saleSupply + liquidityReserve`, con un tetto di 1 miliardo) e il prezzo di
inizializzazione del pool. Per questo lancio la supply totale e' fissata a
**100.000.000 di token esatti**: poiche' la riserva e' il 90% di cio' che si
vende, la supply totale e' 19/10 del venduto, quindi **52.631.578,95 token in
vendita** (100M x 10/19) e 47.368.421,05 di riserva.

### Le fasi

**A. Vendita.** Chiunque compra con `buy()` al prezzo fisso finche' c'e'
disponibilita' e finche' non scade la finestra. Il 10% dell'ETH e' commissione,
il 90% e' vincolato alla liquidita'. I token restano in escrow nel contratto: si
ritirano dopo la migrazione. L'eventuale ETH in eccesso sull'ultimo acquisto
viene restituito nella stessa transazione.

**B. Esito.** Il lancio e' valido se la vendita si esaurisce (in qualsiasi
momento) oppure se alla scadenza e' stato raggiunto il soft cap. Altrimenti e'
fallito, e si apre il rimborso.

**C. Migrazione.** `finalize()` e' **permissionless**: la puo' chiamare
chiunque, non serve il deployer. In una sola transazione il contratto:

1. verifica il prezzo del pool e, se qualcuno lo ha spostato, lo **riporta al
   prezzo di listing** con uno swap a budget limitato;
2. **rifiuta di procedere** se il prezzo o il tick non coincidono esattamente
   con il target (chi manipola il pool blocca la migrazione, non la altera);
3. minta la posizione di liquidita' su un intervallo ampio ma limitato, tramite
   il PositionManager ufficiale di Uniswap v4;
4. **brucia** tutti i token residui non destinati agli acquirenti;
5. restituisce a `feeRecipient` l'ETH avanzato dal mint.

Se la vendita chiude sotto il 100% (caso soft cap), la liquidita' viene
calcolata sul raccolto effettivo: entra nel pool la quantita' di token che
corrisponde all'ETH disponibile a quel prezzo, e **tutto il resto e' bruciato**.
Non esiste uno scenario in cui token invenduti restino nelle mani di qualcuno.

**I numeri di questo lancio.** I parametri sono fissati in
`script/Deploy.s.sol` e sono gli stessi che la suite di test esercita:

| Voce | Valore |
| --- | --- |
| Supply totale coniata | 100.000.000 token (esatti) |
| Token in vendita | 52.631.578,947368421052631579 |
| Riserva di liquidita' | 47.368.421,052631578947368421 |
| Prezzo | 0,00001 ETH per token |
| Soft cap | 26.315.789,47 token (50%) |
| Durata della vendita | 7 giorni |
| Raccolta a vendita esaurita | 526,32 ETH |
| Prezzo di apertura del pool | 0,00001 ETH (tick 115.135) |

A vendita esaurita: **526,32 ETH raccolti**, di cui **52,63 ETH di commissione**
e **473,68 ETH nel pool** insieme a **47.368.421 token**, allo stesso prezzo
della vendita. I 52.631.578,95 token venduti restano in escrow fino al
`claim()`; circa 0,52 ETH (0,11% del budget di liquidita') non entra nella
posizione per arrotondamento e viene spazzato a `feeRecipient` insieme alla
commissione.

Chiusura al soft cap (50%): circa 263 ETH raccolti, 237 ETH nel pool con
23.710.333 token, e vengono bruciati sia la riserva avanzata sia l'invenduto —
circa 49.974.000 token distrutti, supply finale circa 50.026.000. Entrambi gli
scenari sono verificati da `test_soldOutLifecycle` e
`test_softCapFinalizeBurnsUnsoldAndSurplus`.

Un dettaglio di arrotondamento: un wei di ETH compra 100.000 unita' minime di
token, e la quantita' in vendita non e' un multiplo esatto di quel blocco. Per
esaurire la vendita serve **1 wei in piu'** del costo nominale; il surplus viene
comunque rimborsato dallo stesso `buy()`.

**D. Consegna o rimborso.** A migrazione avvenuta ogni acquirente ritira i
propri token con `claim()`. Se invece il lancio e' fallito, `refund()` restituisce
l'intero ETH versato, commissione compresa. La commissione e' prelevabile solo
**dopo** la migrazione: finche' il rimborso e' possibile, resta a garanzia degli
acquirenti.

**E. Vita del pool.** Le swap fee maturate dalla posizione sono raccolte con
`collectPoolFees()`, anch'essa permissionless e con destinatario fissato al
deploy: la chiamata puo' partire da chiunque, l'incasso va sempre e solo a
`feeRecipient`. Il capitale della posizione non viene mai toccato.

## Cosa il lancio **non** promette

Va detto con la stessa chiarezza:

- **Non promette un prezzo.** Il contratto garantisce che il mercato apra al
  prezzo di vendita con liquidita' reale; da li' in poi il prezzo lo fa il
  mercato, e puo' scendere.
- **Non elimina il rischio di controparte sulle commissioni.** `feeRecipient`
  incassa il 10% della raccolta e le swap fee perpetue. E' un indirizzo fissato
  al deploy e non modificabile, ma resta una concentrazione economica: chi
  valuta il lancio deve sapere chi e'.
- **Non e' immune al grief.** Un terzo con capitale sufficiente puo' manipolare
  il pool in modo che la migrazione reverta. Non ci guadagna nulla e non tocca i
  fondi: l'effetto e' che, passati 3 giorni dalla scadenza, gli acquirenti
  rientrano interamente dei propri versamenti.
- **Non e' un audit.** Il repository contiene analisi statica, 19 test e
  invarianti verificate su 150.000 chiamate (vedi
  [testing.md](testing.md) e [findings.md](findings.md)); il codice di
  integrazione con Uniswap v4 e' custom e va sottoposto a revisione
  indipendente prima di gestire fondi reali.

## Verificabilita'

Le proprieta' dichiarate qui non sono affermazioni di marketing: ognuna
corrisponde a un'invariante numerata nell'header del contratto e a un test che
la esercita. La mappa completa — quale test copre quale invariante, con quali
numeri — e' in [testing.md](testing.md).
