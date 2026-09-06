# Dipendenze

Tutte le dipendenze stanno in `lib/` come git submodule pinnati a un commit
esatto (nessun tag mobile, nessuna versione "latest").

| Path | Repo | Commit |
| --- | --- | --- |
| `lib/v4-core` | Uniswap/v4-core | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` (v1.0.2) |
| `lib/v4-periphery` | Uniswap/v4-periphery | `ad04c9f24a170accf5ea1b2836bbafd514537ca6` (v1.0.2) |
| `lib/permit2` | Uniswap/permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` |
| `lib/openzeppelin-contracts` | OpenZeppelin/openzeppelin-contracts | `21c8312b022f495ebe3621d5daeed20552b43ff9` |
| `lib/forge-std` | foundry-rs/forge-std | `3b20d60d14b343ee4f908cb8079495c07f5e8981` (1.9.6) |
| `lib/v4-core/lib/solmate` | transmissions11/solmate | `4b47a19038b798b4a33d9749d25e570443520647` |

`solmate` sta **dentro** `lib/v4-core/lib/` perche' e' li' che lo cercano gli
import di v4-core (`solmate/=lib/solmate/` nel suo `remappings.txt`). E' un
submodule di v4-core, non del progetto: v4-core lo pinna esattamente al commit
`4b47a19`, lo stesso usato qui.

## Installazione e verifica

```bash
make install      # inizializza i submodule di primo livello + solmate dentro v4-core
make deps-check   # verifica che ogni dipendenza sia al commit pinnato
```

`make install` non usa `--recursive`: il checkout ricorsivo tirerebbe giu' anche
le dipendenze annidate che non servono (forge-std e openzeppelin dentro v4-core,
i submodule di permit2, una seconda copia di v4-core dentro v4-periphery).

## Remapping

`remappings.txt` mappa i prefissi usati dai contratti del progetto e dalle
dipendenze:

```
forge-std/=lib/forge-std/src/
@openzeppelin/=lib/openzeppelin-contracts/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
openzeppelin-contracts/contracts/=lib/openzeppelin-contracts/contracts/
solmate/=lib/v4-core/lib/solmate/
permit2/=lib/permit2/
@uniswap/v4-core/=lib/v4-core/
v4-core/=lib/v4-core/src/
v4-periphery/=lib/v4-periphery/src/
```

Due note:

- v4-periphery importa sia `@openzeppelin/contracts/...` sia
  `openzeppelin-contracts/contracts/...`: entrambi i prefissi puntano allo
  stesso clone in `lib/openzeppelin-contracts`.
- `@openzeppelin/=lib/openzeppelin-contracts/` sovrascrive il remapping che
  forge auto-rileva dal `remappings.txt` di v4-core
  (`@openzeppelin/=lib/v4-core/lib/openzeppelin-contracts/`), che punterebbe a
  una directory non inizializzata. Controllare il risultato con
  `forge remappings`.

`test/Dependencies.t.sol` e' lo smoke test che tiene onesti i remapping: importa
v4-core, v4-periphery, permit2 e OpenZeppelin, e deploya `PoolManager` con il
profilo di compilazione del progetto (19.713 byte di runtime, sotto il limite
EIP-170 anche senza `via_ir`).

## Aggiornare una dipendenza

```bash
git -C lib/<dep> fetch origin
git -C lib/<dep> checkout <nuovo-commit>
git add lib/<dep>
# aggiornare la tabella qui sopra e, se e' solmate, anche tools/check-deps.sh
make build test analyze
```

Le dipendenze sono escluse dall'analisi statica (`filter_paths` in
`slither.config.json`, `exclude` in `aderyn.toml`): si analizza il codice del
progetto, non quello di terze parti. I warning del compilatore provenienti da
`lib/` non fanno fallire la build (`ignored_warnings_from` in `foundry.toml`),
quelli del codice del progetto si'.
