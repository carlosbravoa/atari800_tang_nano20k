# Brief: Spanish translation of the Tang Atari 800 user manual

Repo: /home/carlos/devel/fpga/atari800_tang_nano20k_parallel
Source pages: manual/<name>.html (English). Target: manual/es/<same name>.html (Spanish).
Write the target with the Write tool. Do NOT modify any English file. Do not touch git.

## Audience and register
Latin American Spanish for an Atari hobbyist community in Chile. Address the reader as "tú"
(imperativo: "abre el menú", "conecta el cable"). Neutral vocabulary: "computador" or "PC"
(never "ordenador"), "video" (no accent), "tarjeta SD", "placa" (the board), "conector",
"cable", "puerto". Natural, clear Spanish — a good human technical translation, not
word-for-word. Keep sentence meaning exact: this is a manual, every detail matters (pin
numbers, key names, file names, limits, warnings). Never drop a sentence, never add facts.

## What stays in English, verbatim
- Everything inside <code>, <pre>, <kbd>: commands, file names, paths, key caps (F12, Enter,
  Esc, Shift, Ctrl, Alt, S1, S2), register names, ini keys. Leave untouched.
- Text that appears ON THE ATARI SCREEN or in the OSD menu: menu items such as
  "Boot to OS (No BASIC)", "Boot to BASIC", "Soft Reset", "Hard Reset", "Options",
  "Return to Atari (Esc)", "Attach", "Detach", "New blank disk", "Save changes",
  "Arrow keys", "Scanlines", "H position", "Stereo", "RAM", "Modem (R:)", "Keyboard",
  "Insert SD card, then press S1", "READY", "BOOT ERROR", etc. Keep them exactly as the
  English page shows them (they are what the user will see on screen), and where the
  English page uses them as a plain noun add a short Spanish gloss the FIRST time on a page,
  e.g. <strong>7) Hard Reset</strong> (reinicio en frío).
- Product and feature names: Tang Nano 20K, Sipeed, Atari 800XL, PC Link, OSD, HDMI, FPGA,
  BASIC, DOS, SIO, POKEY, ANTIC, GTIA, CH9350, BL616, FatFs, openFPGALoader, GitHub.
- URLs, hrefs, image src, ids, class names, all HTML structure and attributes except the
  text ones listed below.

## What gets translated
- All running text, headings, table cells, list items, <figcaption>, alt="" text,
  <title>, aria-label, the header subtitle, the footer prev/next labels.
- Translate <title> as: "<n>. <Título del capítulo> — Manual Tang Atari 800"
  (index: "Tang Atari 800 — Manual de usuario").

## Glossary (use these consistently)
| English | Spanish |
|---|---|
| User manual | Manual de usuario |
| Contents | Índice |
| Overview | Introducción |
| Hardware setup | Instalación del hardware |
| Getting started | Primeros pasos |
| The OSD menu | El menú OSD |
| Options & atari.ini | Opciones y atari.ini |
| Disks | Discos |
| Cartridges | Cartuchos |
| Executables (.xex) | Ejecutables (.xex) |
| Keyboard | Teclado |
| Video | Video |
| Audio | Audio |
| RAM expansion | Ampliación de RAM |
| PC Link | PC Link |
| Troubleshooting | Solución de problemas |
| Known issues | Problemas conocidos |
| Appendix | Apéndice |
| board | placa |
| bitstream | bitstream (masc.: "el bitstream") |
| flash (verb) / flashing | grabar / grabación (first time: "grabar (flashear)") |
| power-cycle | apagar y volver a encender |
| power-on | encendido |
| cold boot / warm reset | arranque en frío / reinicio en caliente |
| Hard Reset / Soft Reset (menu items) | keep English; gloss: reinicio en frío / reinicio en caliente |
| mount / attach (a disk) | montar / adjuntar (menu item "Attach" stays English) |
| eject / detach | expulsar / desconectar ("Detach" stays English) |
| drive (D1:) | unidad |
| disk image | imagen de disco |
| blank disk | disco en blanco |
| read-only | solo lectura |
| write-protected | protegido contra escritura |
| cartridge | cartucho |
| multicart / multi-game cartridge | cartucho multijuego |
| executable | ejecutable |
| joystick | joystick |
| keyboard adapter | adaptador de teclado |
| jumper wire | cable (de puente) |
| header pin | pin del conector |
| pinout | asignación de pines (pinout) |
| scanlines | scanlines (líneas de barrido) — first time gloss, then "scanlines" |
| horizontal position | posición horizontal |
| stereo | estéreo |
| file browser | explorador de archivos |
| hotkey | tecla rápida |
| status LED | LED de estado |
| heartbeat | latido (heartbeat) |
| release (GitHub) | versión publicada (release) |
| firmware | firmware |
| core | núcleo (core) |
| screen / display | pantalla |
| monitor / TV | monitor / televisor |
| framing / frame | cuadro |
| black-out (HDMI) | pérdida de señal |
| latency / lag | latencia / retardo |
| freeze | se congela / congelamiento |
| garbled | corrupto / con basura |
| wedge / stuck | queda trabado |
| serial bridge | puente serial |
| type (paste as keystrokes) | teclear / "escribir como pulsaciones" |
| printer capture | captura de impresora |
| Previous / Next (footer) | Anterior / Siguiente |

## Fixed HTML blocks (paste exactly; only the class="cur" marker moves to the current page)

Head (replace lang, title; style/font links use ../):
```
<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>3. Primeros pasos — Manual Tang Atari 800</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;600&family=IBM+Plex+Mono:wght@400;500&display=swap">
<link rel="stylesheet" href="../style.css"></head>
<body>
<header class="top"><a class="brand" href="index.html">Tang Atari 800</a><span class="sub">Manual de usuario</span><a class="lang" href="../SAMENAME.html" lang="en">English</a></header>
<div class="wrap">
```
(SAMENAME = this page's own file name, e.g. ../03-getting-started.html)

Nav (identical on every page; put class="cur" on the current page's <a>):
```
<nav class="side" aria-label="Capítulos"><ol>
<li><a href="index.html"><span class="num">≡</span>Índice</a></li>
<li><a href="01-overview.html"><span class="num">1</span>Introducción</a></li>
<li><a href="02-hardware.html"><span class="num">2</span>Instalación del hardware</a></li>
<li><a href="03-getting-started.html"><span class="num">3</span>Primeros pasos</a></li>
<li><a href="04-osd.html"><span class="num">4</span>El menú OSD</a></li>
<li><a href="05-options.html"><span class="num">5</span>Opciones y atari.ini</a></li>
<li><a href="06-disks.html"><span class="num">6</span>Discos</a></li>
<li><a href="07-cartridges.html"><span class="num">7</span>Cartuchos</a></li>
<li><a href="08-executables.html"><span class="num">8</span>Ejecutables (.xex)</a></li>
<li><a href="09-keyboard.html"><span class="num">9</span>Teclado</a></li>
<li><a href="10-video.html"><span class="num">10</span>Video</a></li>
<li><a href="11-audio.html"><span class="num">11</span>Audio</a></li>
<li><a href="12-ram.html"><span class="num">12</span>Ampliación de RAM</a></li>
<li><a href="13-pc-link.html"><span class="num">13</span>PC Link</a></li>
<li><a href="14-troubleshooting.html"><span class="num">14</span>Solución de problemas</a></li>
<li><a href="15-known-issues.html"><span class="num">15</span>Problemas conocidos</a></li>
<li><a href="16-appendix.html"><span class="num">A</span>Apéndice</a></li>
</ol></nav>
```

Footer pattern:
```
<footer class="pn"><a href="02-hardware.html">← Anterior: Instalación del hardware</a><a href="04-osd.html">Siguiente: El menú OSD →</a></footer>
```

## Paths
- Internal links between chapters stay relative and unchanged (e.g. href="06-disks.html")
  because the Spanish pages live together in manual/es/.
- Images: every src="img/..." becomes src="../img/..." (images are shared, not copied).
- style.css → ../style.css (already in the head block above).

## Quality bar
- Read the whole English page first, then write the whole Spanish page in one Write call.
- Preserve every HTML element, attribute, id and class; the translated page must have the
  same structure line for line where practical.
- Numbers, pin numbers, units, key names, ranges and defaults must be identical to the
  English.
- After writing, reread your output once for: untranslated English sentences left behind,
  broken tags, img paths not starting with ../img/, missing class="cur", wrong lang.
- Report at the end: files written, and any sentence you were unsure how to translate
  (quote it) so the reviewer can check.
