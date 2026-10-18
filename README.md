# 🍊 Clementine

Convertitore e modificatore di file per macOS, ispirato a Tangerine e ricostruito da zero.
Tutto avviene sul Mac: nessun file viene mai caricato online. È gratuito e senza limiti.

## Come si usa

| Gesto | Cosa succede |
|---|---|
| Trascina un file nel Finder tenendo **⇧ (Maiusc)** | Si apre la ruota dei **formati**: rilascia il file sul formato voluto |
| **⇧ + ⌥ (Opzione)** durante il trascinamento | Ruota degli **strumenti** (comprimi, taglia, ruota, metadati…) |
| **⇧ + ⌃ (Control)** | Ruota delle **azioni** (AirDrop, copia percorso, Terminale, sposta, file fluttuanti) |
| Trascina file sulla finestra o scegli dal menu | Si apre la ruota cliccabile (frecce + Invio, Tab per cambiare ruota, Esc per chiudere) |

Il risultato viene salvato **accanto all'originale** (che non viene mai toccato) e mostrato nel Finder.
Se trascini più file insieme, l'operazione viene applicata a tutti; alcune li combinano (unisci PDF/video/audio, collage, ZIP).

## Cosa sa fare

- **Immagini**: JPG, PNG, HEIC, WebP, AVIF, TIFF, GIF, BMP, PDF · comprimi a dimensione o %, ridimensiona, ruota, rifletti, bianco e nero, migliora automaticamente, **rimuovi sfondo**, togli/leggi metadati, leggi QR, **riconoscimento testo (OCR)**, collage, unisci in PDF
- **Video**: MP4, MOV, MKV, WebM, AVI, WMV, GIF, estrazione audio · comprimi a dimensione, taglia, ritaglia (16:9, 9:16, 1:1…), velocità, 720p, togli audio, fotogramma, dividi, unisci, metadati
- **Audio**: MP3, M4A, WAV, FLAC, OGG, Opus, AIFF · normalizza, taglia, comprimi, bleep, mono/stereo, velocità, riduzione rumore, titolo/artista, unisci
- **PDF**: in PNG/JPG/TXT/DOCX/RTF · unisci, dividi, estrai/riordina pagine, ruota, comprimi, proteggi con password, metadati
- **Documenti**: DOCX, DOC, ODT, RTF, HTML, TXT, Markdown ↔ PDF/DOCX/TXT/… · statistiche, unisci in PDF
- **Sottotitoli**: SRT ↔ VTT, sposta i tempi, estrai solo testo
- **Archivi**: estrai ZIP/TAR/GZ, crea ZIP e TAR.GZ

## Installazione (senza programmare)

1. Su GitHub apri la scheda **Actions** → ultima esecuzione verde di *Build macOS app* → scarica l'artefatto **Clementine**.
2. Decomprimi e trascina `Clementine.app` in **Applicazioni**.
3. Al primo avvio: tasto destro sull'app → **Apri** → **Apri** (l'app non è firmata da uno sviluppatore Apple registrato).
4. Compare l'icona 🍊 nella barra dei menu in alto.

**ffmpeg** (necessario per MKV, WebM, MP3, FLAC, compressione video, ecc.) è già incluso nella versione per Apple silicon.
Se manca, installalo dal Terminale con `brew install ffmpeg`.

## Compilare in locale (sviluppatori)

```bash
./build-app.sh      # crea dist/Clementine.app
```
Richiede macOS 13+ e Xcode o i Command Line Tools.
