# Snoredle — plan om te commercialiseren

## 1. Naam
"SnoreLab" kan **niet**: dat is een bestaande, bekende app (Reviva Softworks), ook in het Nederlands als SnurkLab. Gebruik ook niets dat erop lijkt.

Gekozen naam: **Snoredle** (snore + speels "-dle"). Internationaal bruikbaar, één woord, goed te googelen.
In de App Store vond ik geen app met die naam.

Nog te doen vóór lancering:
- Merk controleren en registreren bij BOIP (Benelux) of EUIPO (hele EU), klasse 9 (software) en 44 (gezondheid)
- Domein vastleggen: snoredle.com / snoredle.app / snoredle.be
- Instagram/TikTok-account reserveren
- Opgelet: "-dle" doet denken aan Wordle (New York Times). Gebruik geen gelijkende huisstijl (groen/geel tegeltjes), dan is er geen probleem.

App Store-titel: "Snoredle – Snurk & Watch-tikje", met ondertitel "Snore tracker met slaaphouding".

## 2. Waarmee je opvalt
De bekende apps meten alleen geluid. Snoredle combineert:
1. Snurken **gekoppeld aan je houding** ("op je rug snurk je 3,4× zoveel")
2. Een **tikje op de pols** als je op je rug snurkt (houdingstherapie, zonder extra hardware)
3. Hartslag, SpO₂ en ademhaling van je watch in hetzelfde nachtrapport
4. Werkt met meerdere watches (Apple Watch, plus alles wat via Gezondheid of Bluetooth deelt)

Gebruikers van andere snurk-apps vragen hier openlijk om; zo zei een recensent van Snore Control dat hij Pro zou kopen als er Apple Watch-trillen bij kwam.

## 3. Andere watches: stappenplan
| Fase | Platform | Hoe | Wat je krijgt |
|---|---|---|---|
| 1 (klaar) | Apple Watch | eigen watchOS-app | alles: houding, hartslag, tikjes |
| 1 (klaar) | Garmin, Withings, Oura, Polar, Zepp… | via Apple Gezondheid | hartslag, SpO₂, ademhaling (achteraf) |
| 1 (klaar) | Garmin/Polar/Coros "broadcast HR", borstbanden | Bluetooth 0x180D | live hartslag |
| 2 | Android-telefoon + Wear OS (Samsung, Pixel) | Android-app in Kotlin + Wear OS-app; zelfde `WatchMessage`-JSON | alles |
| 3 | Garmin | Connect IQ-app (Monkey C) die houding + tikje doet, communiceert met de telefoon-app | houding, tikjes |
| 4 | Fitbit | Fitbit Web API (achteraf), geen live sensoren meer voor derde partijen | hartslag, SpO₂ |

De iPhone-code heeft al een `WearableProvider`-interface: elke nieuwe watch is één extra klasse.

Voor Android (fase 2): overweeg de telefoonkant in **Kotlin Multiplatform** te schrijven, zodat analyse en score gedeeld worden. Of herbouw de iPhone-app in Flutter, maar dan blijven de watch-apps toch native.

## 4. Verdienmodel
- **Gratis**: meten, score, 7 nachten geschiedenis, 5 fragmenten per nacht
- **Snoredle Plus**: €4,99/maand · €29,99/jaar · €59,99 levenslang
  - onbeperkte geschiedenis, alle fragmenten, watch-houding + tikjes, inzichten, gezondheidsdata, PDF voor de arts
- Gratis proefperiode van 7 dagen op het jaarabonnement (standaard in deze categorie)

Apple houdt 15% in (Small Business Program, < $1M/jaar) en 30% daarboven.

## 5. Wettelijk (EU/België) — niet overslaan
- **Geen medisch hulpmiddel**: positioneer als "wellness/lifestyle". Geen claims als "detecteert slaapapneu". Doe je dat wel, dan valt je app onder de EU MDR (klasse IIa) met CE-markering via een notified body: duur en traag.
- **AVG/GDPR**: gezondheidsdata zijn "bijzondere persoonsgegevens". Alles blijft op het toestel (zo is de code gebouwd), dat houdt het eenvoudig. Toch nodig: privacybeleid, expliciete toestemming, verwijderknop. Voeg je later cloud-sync toe → verwerkersovereenkomst, EU-hosting, DPIA.
- **Partner**: de microfoon neemt ook de partner op. Zet dat in de onboarding en het privacybeleid.
- **Bedrijf**: onderneming/eenmanszaak en KBO-nummer, Apple Developer-account op bedrijfsnaam (D-U-N-S-nummer nodig).
- Laat het privacybeleid en de voorwaarden nalezen door een jurist.

## 6. Roadmap
1. **Maand 1**: bouwen en testen op jezelf + 10–20 testers via TestFlight. De gevoeligheid en dB-kalibratie afstellen met echte nachten.
2. **Maand 2**: App Store-lancering Benelux (NL/FR), landingspagina, privacybeleid.
3. **Maand 3–4**: eigen snurkmodel trainen met Create ML op (geanonimiseerde, met toestemming gedeelde) fragmenten → nauwkeuriger dan Apple's algemene classifier. Partner-modus (2 snurkers onderscheiden).
4. **Maand 4–6**: Android + Wear OS.
5. Later: Garmin Connect IQ, slimme wekker, samenwerking met tandartsen (snurkbeugels) en NKO-artsen.

## 7. Nog te beslissen
- Logo en huisstijl
- Prijzen
- Alleen Benelux of meteen de hele EU (vertalingen: EN, FR, DE)
