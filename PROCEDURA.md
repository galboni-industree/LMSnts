# NTS Radio — Procedura di installazione "installa e dimentica"

Guida operativa per installare il plugin su LMS in modo **sicuro** (senza
rischiare di rovinare o sporcare il sistema) e **definitivo** (se funziona, non
devi più toccare nulla). Ogni passaggio critico ha un **Piano B**.

> Regola d'oro: **prima leggi, poi esegui un passo alla volta.** Dopo ogni passo
> c'è una verifica. Se la verifica non è verde, fermati e applica il Piano B
> prima di proseguire.

---

## Garanzie di sicurezza (perché non sporca/rovina il sistema)

* **Tutto è contenuto in una sola cartella:** `/var/lib/squeezeboxserver/Plugins/NTSRadio`.
  Nient'altro del sistema viene modificato.
* **Nessun pacchetto di sistema installato, nessuna dipendenza CPAN nuova.** Usa
  solo moduli già presenti in LMS (`Slim::*`, `JSON::XS`, `IO::Socket::SSL`).
* **Nessuna modifica al core di LMS**, nessun file di sistema, nessun cron, nessun
  servizio aggiuntivo.
* **Gli script hanno guardie sul percorso:** `deploy.sh` e `undeploy.sh` si
  rifiutano di operare se la destinazione non è esattamente `.../Plugins/NTSRadio`,
  quindi un `--delete`/`rm` non può colpire altro.
* **Backup automatico** della versione precedente in `~/nts-backups/` prima di
  sovrascrivere (i backup stanno nella tua home, non nell'albero di LMS).
* **Disinstallazione pulita** con `./undeploy.sh`: rimuove solo quella cartella e
  riavvia LMS, riportando il sistema esattamente com'era.

---

## Garanzie di "zero manutenzione" (perché non dovrai più toccarlo)

* **Non si blocca mai:** ogni lettura dell'API è sotto `eval` difensivo; JSON
  malformato o API irraggiungibile → log e si prosegue, **l'audio non si ferma**.
* **Si auto-ripara:** il timer di polling viene **sempre** riprogrammato anche se
  una richiesta fallisce; non esistono timer orfani (uno solo, idempotente).
* **Nessuno stato persistente da gestire:** i metadati stanno in memoria; al
  riavvio si ripopolano da soli entro ~60 s.
* **Niente da aggiornare:** nessuna libreria esterna, nessuna chiave/API key,
  nessun account.
* L'**unico** evento che in futuro potrebbe richiedere un micro-intervento è che
  NTS cambi gli URL dello stream o dell'API (cosa fuori dal nostro controllo).
  Anche in quel caso il plugin **degrada con grazia** e la correzione è una riga
  (vedi sezione "Manutenzione futura — l'unico caso").

---

## Passo 0 — Portare i file sul dispositivo LMS

**Obiettivo:** avere la cartella del progetto sul box LMS.

```bash
# Sul dispositivo LMS, come utente normale (NON root):
git clone -b claude/nts-radio-lms-plugin-eWd59 https://github.com/galboni-industree/LMSnts.git ~/nts-plugin
cd ~/nts-plugin
```

**Verifica:** `ls src/NTSRadio` mostra `install.xml Plugin.pm strings.txt HTML`.

**Piano B (no git / no rete sul box):** clona il repo su un altro computer
(`git clone -b claude/nts-radio-lms-plugin-eWd59 https://github.com/galboni-industree/LMSnts.git`)
e copia la cartella via `scp`: `scp -r LMSnts utente@IP_DEL_BOX:~/nts-plugin` —
oppure via chiavetta USB. Il contenuto necessario è solo la cartella
`src/NTSRadio` più gli script `*.sh`.

---

## Passo 1 — Pre-flight (controlli a sola lettura) 🔵 CRITICO

**Obiettivo:** verificare l'ambiente **senza modificare nulla**.

```bash
./preflight.sh
```

**Verifica:** vuoi 0 `FAIL`. I `WARN` di rete (stream/API non raggiungibili in
quel momento) **non bloccano**: il plugin parte comunque e si popola appena la
rete torna.

**Verifica (note importanti):**
* **`JSON::XS`** può risultare assente nel Perl *di sistema*: non è un problema.
  Il plugin usa `JSON::XS` se c'è (LMS lo include) e **altrimenti ripiega su
  `JSON::PP`** (modulo core). Il preflight infatti dà `OK` se trova l'uno o
  l'altro.
* Il **nome del servizio** viene **auto-rilevato** dagli script (prova
  `lyrionmusicserver`, `squeezeboxserver`, `logitechmediaserver`, ecc.). Se il
  preflight non lo trova, te lo dice e ti dà il comando per scoprirlo.

**Piano B:**
* `FAIL` su `IO::Socket::SSL`: improbabile su LMS 9.1.1. Se accade, **non
  procedere**: verifica di essere sul box giusto. Non installare CPAN a mano.
* `FAIL` su JSON (né `JSON::XS` né `JSON::PP`): non procedere e segnalamelo.
* **Servizio non rilevato:** trovalo con
  `systemctl list-units --type=service --all | grep -iE "lyrion|squeeze|logitech|slim|lms"`
  e dimmi il nome (lo aggiungo all'auto-detect, oppure lo riavvii a mano).
* **`WARN` su API** (lo stream va ma l'API no): il preflight prova prima con
  l'User-Agent del plugin e poi con uno "da browser". Se l'API risponde **solo**
  con l'UA da browser, è un filtro anti-bot: **segnalamelo**, faccio mandare al
  plugin un UA da browser. Comando di diagnosi suggerito dallo stesso preflight:
  `curl -sS -v --max-time 10 -A "Mozilla/5.0" 'https://www.nts.live/api/v2/live' | head -c 400`.
  In ogni caso l'audio funziona; i metadati arrivano appena l'API è raggiungibile.

---

## Passo 2 — Deploy 🔴 CRITICO (qui si tocca il sistema)

**Obiettivo:** copiare il plugin, sistemare i permessi, riavviare LMS — con
backup e controllo automatico del log.

```bash
./deploy.sh
```

Lo script, in ordine: valida i file → controllo sintassi di `Plugin.pm` →
**backup** dell'eventuale versione precedente in `~/nts-backups/` → copia →
`chown squeezeboxserver:nogroup` → riavvia LMS → controlla il log.

**Verifica:** alla fine compare `no NTSRadio errors detected in the log so far` e
parte il tail del log senza righe `error/fail/Can't locate` relative a NTSRadio.
(Premi `Ctrl-C` per uscire dal tail: non interrompe nulla.)

**Piano B:**
* Lo script avvisa di **possibili errori nel log**: leggi le righe mostrate. Per
  tornare **immediatamente** allo stato precedente:
  ```bash
  ./undeploy.sh           # rimuove il plugin e riavvia LMS
  ```
  Il sistema torna esattamente com'era. Poi incolla a me le righe di log per la
  correzione.
* LMS **non riparte** dopo il restart: il plugin è in `defaultState=disabled`,
  quindi non viene nemmeno caricato finché non lo abiliti (Passo 3) — è molto
  improbabile che il deploy impedisca l'avvio. Se comunque succede:
  ```bash
  ./undeploy.sh
  sudo systemctl status lyrionmusicserver --no-pager
  ```
* Vuoi ripristinare una versione precedente specifica: i backup sono in
  `~/nts-backups/NTSRadio-*.tgz` (scompattali in `.../Plugins/`).

---

## Passo 3 — Abilitare il plugin (una tantum) 🟠 CRITICO

**Obiettivo:** attivare il plugin in LMS. È l'**unica** azione manuale richiesta,
e una volta sola.

1. Web UI di LMS → **Settings → Manage Plugins**.
2. Spunta **NTS Radio** → **Apply** → conferma il riavvio.

**Verifica:** dopo il riavvio, in **Manage Plugins** NTS Radio risulta abilitato e
senza errori.

**Piano B:**
* Dopo l'abilitazione LMS si comporta male: **disabilita** NTS Radio dalla stessa
  pagina e applica. Se la UI è irraggiungibile:
  ```bash
  ./undeploy.sh
  ```
* Il plugin non compare proprio nell'elenco: di solito `install.xml` non è stato
  letto. Controlla i permessi (`ls -l /var/lib/squeezeboxserver/Plugins/NTSRadio`
  deve essere di `squeezeboxserver`) e cerca nel log:
  `sudo grep -i ntsradio /var/log/squeezeboxserver/server.log`.

---

## Passo 4 — Verifica funzionale 🟢

**Obiettivo:** confermare che tutto funziona come da specifica.

1. Menu **Radio → NTS Radio** → vedi **NTS 1** e **NTS 2**.
2. Play **NTS 1**: audio entro pochi secondi.
3. Entro **≤ ~60 s** compaiono **titolo dello show** e **copertina**; al cambio
   show si aggiornano da soli.
4. (Se hai 2 player) NTS 2 in parallelo mostra metadati distinti e corretti.
5. (Opzionale) Aggiungi NTS 1 ai **Preferiti** e riproduci dal preferito: i
   metadati si risolvono comunque.

**Piano B (audio ok ma metadati assenti):**
* Alza il log: **Settings → Advanced → Logging → `plugin.ntsradio` = DEBUG**,
  riproduci, poi:
  `sudo grep -i ntsradio /var/log/squeezeboxserver/server.log | tail -40`.
* Casi tipici: il provider non viene interrogato (URL non coperto dalla regex) o
  l'API restituisce una struttura diversa. Incolla a me quelle righe: la
  correzione è mirata e si ri-deploya con `./deploy.sh` (di nuovo con backup).
* **Importante:** anche con i metadati assenti, **l'audio continua a funzionare**.
  Nessuna urgenza, nessun rischio per il sistema.

**Piano B (audio non parte):**
* Verifica lo stream a mano:
  `curl -sI -L 'https://stream-relay-geo.ntslive.net/stream?client=direct'`
  (atteso `content-type: audio/mpeg`). Se l'URL NTS è cambiato, vedi la sezione
  seguente.

---

## Manutenzione futura — l'unico caso possibile

Il solo scenario che potrebbe richiedere un intervento è un cambiamento **lato
NTS** (non nel nostro codice):

| Cosa cambia da NTS | Sintomo | Correzione (una riga) |
|---|---|---|
| URL dello stream | l'audio non parte più | aggiorna `URL_CH1` / `URL_CH2` in `src/NTSRadio/Plugin.pm`, poi `./deploy.sh` |
| Path/struttura dell'API | i metadati smettono di aggiornarsi (ma l'audio va) | aggiorna `API_URL` o il parsing in `_gotLive`, poi `./deploy.sh` |
| Host edge (radiomast) | metadati assenti su alcuni player | la regex `MATCH` già copre `radiomast.io`; in caso aggiungi il nuovo host |

In tutti i casi il plugin **non si rompe e non rompe LMS**: degrada con grazia.
Ogni correzione passa sempre da `deploy.sh`, quindi con backup automatico e
possibilità di `undeploy.sh`.

---

## Disinstallazione pulita (ritorno a sistema pristino)

```bash
./undeploy.sh                 # rimuove SOLO .../Plugins/NTSRadio e riavvia LMS
rm -rf ~/nts-backups          # opzionale: elimina anche i backup, zero tracce
```

Dopo questo, del plugin non resta nulla nel sistema.

---

## Riepilogo comandi

```bash
./preflight.sh   # controlli a sola lettura (sicuro, non cambia niente)
./deploy.sh      # installa/aggiorna (con backup + controllo log)
./undeploy.sh    # rimuove tutto e riavvia LMS (rollback pulito)
```
