# CapCut Transfer

App macOS per trasferire progetti CapCut tra Mac, raccogliendo i file multimediali collegati e aggiornando i percorsi durante l'importazione.

> **Una nota prima di tutto:** non sono un programmatore. Questa app è stata fatta con l'intelligenza artificiale, in *vibecoding*: io ho descritto cosa mi serviva e l'AI ha scritto il codice. L'ho messa online solo sperando che possa essere utile a qualcuno che, come me, ha bisogno di spostare i progetti CapCut da un Mac all'altro.
>
> Funziona per quello che mi serviva, ma non posso garantire niente: prima di usarla su un progetto importante, tieni una copia di sicurezza.

**Versione 1.0.0 · Mac Intel e Apple Silicon · macOS 12 o successivo.**

Nessun aggiornamento automatico: le nuove versioni si scaricano e si installano manualmente dalla pagina [Releases](https://github.com/enrik891/capcut-transfer/releases).

## Installazione

1. Apri [Releases](https://github.com/enrik891/capcut-transfer/releases) e scarica `CapCut-Transfer-Mac-1.0.0.zip` dagli allegati della release.
2. Estrai lo ZIP e trascina `CapCut Transfer.app` in Applicazioni.
3. L'app non è notarizzata Apple: macOS potrebbe richiedere l'autorizzazione in Impostazioni di Sistema → Privacy e sicurezza dopo il primo tentativo di apertura.
4. Per aggiornare, chiudi l'app e sostituiscila con la nuova copia.


## Uso

1. Apri l'app: nella scheda **Esporta** compaiono i progetti di `~/Movies/CapCut/User Data/Projects/com.lveditor.draft` con copertina, durata, peso e stato. Se CapCut usa un'altra cartella, cambiala dalla scheda **Importa** (pulsante *Cambia…*).
2. Chiudi CapCut: lo stato in alto a destra si aggiorna da solo e c'è un pulsante per chiuderlo.
3. Seleziona uno o più progetti (⌘ o ⇧ per la selezione multipla) e premi **Esporta**. I progetti con file mancanti sono segnalati prima di iniziare, con l'elenco dei file.
4. Durante la copia vedi avanzamento, dimensioni e tempo stimato; puoi annullare senza lasciare file parziali.
5. Copia il pacchetto `.capcuttransfer` sull'altro Mac. Per AirDrop, chiavetta o disco esterno va bene così com'è; per Google Drive, WeTransfer o email spunta **Crea anche un .zip per l'invio online** prima di esportare e invia il file `.zip`. Sul secondo Mac, con questa versione installata, il pacchetto appare come un singolo file: fai doppio clic, trascinalo nella finestra o usa *Scegli pacchetto…*.
6. Controlla i dettagli (Mac di origine, versione di CapCut, dimensioni) e premi **Importa**. Ogni file viene verificato con il suo checksum SHA-256: se qualcosa si è danneggiato nel trasferimento, l'importazione si ferma.
7. Apri CapCut e cerca il progetto con suffisso `(importato)`.

L'app è in italiano o in inglese secondo la lingua del Mac. I pacchetti creati con la 0.1.x si importano normalmente, senza controllo d'integrità. Il progetto originale non viene mai modificato; l'importazione crea una nuova cartella e un backup dell'indice CapCut.

## Limiti e verifiche

Prima versione sperimentale, verificata con progetti sintetici: copia media, aggiornamento percorsi, conservazione originali, importazioni ripetute, backup indice, gestione dei JSON accessori vuoti e riconoscimento di CapCut aperto.

Il trasferimento completo con apertura ed esportazione in CapCut su un secondo Mac deve ancora essere validato. Usa la stessa versione di CapCut sui due Mac. Effetti online, font, licenze Pro e risorse non referenziate come percorsi nei JSON possono richiedere interventi manuali. Formati cifrati o non riconosciuti non sono supportati. Scarica prima i media disponibili solo su Google Drive o iCloud.

L'app non invia dati online. Se apri una segnalazione su GitHub, non allegare progetti o pacchetti di montaggio: possono contenere materiale privato.

## English

CapCut Transfer moves CapCut projects from one Mac to another, together with the videos, photos and audio they use, and fixes the file paths on the other Mac. The app follows your Mac's language (Italian or English).

> I'm not a programmer: this app was made with AI ("vibecoding"). I shared it hoping it helps someone like me. It works for what I needed, but there are no guarantees: keep a backup before using it on an important project.

1. Download `CapCut-Transfer-Mac-1.0.0.zip` from [Releases](https://github.com/enrik891/capcut-transfer/releases), unzip it and move the app to Applications. The app isn't notarized by Apple: the first time, allow it in System Settings → Privacy & Security.
2. Quit CapCut. In **Export**, select one or more projects and click **Export**. Tick **Also create a .zip for sending online** if you'll send it through Google Drive, WeTransfer or email.
3. On the other Mac, open the package (double-click, drag it into the window, or **Choose Package…**) and click **Import**. Every file is checked for damage.
4. Open CapCut and look for the project ending in “(imported)”. Use the same CapCut version on both Macs; online effects, fonts and Pro licences may need a manual check.

## Compilazione

Servono macOS, Xcode Command Line Tools e Python 3. Non servono dipendenze esterne.

```sh
bash build.sh
```

Il risultato è `dist/CapCut Transfer.app` e il relativo ZIP universale per Intel e Apple Silicon. La firma di sviluppo locale non sostituisce firma Developer ID e notarizzazione Apple.

## Licenza

Software proprietario per uso interno; vedi [LICENSE](LICENSE).
