# Maschinen und Drucker

Worauf Sie drucken und – wenn Sie einen verbinden – was er gerade tut.

## Eine Maschine hinzufügen

Eine Maschine ist ein Datensatz: ihr Name, ihre Art, ihre Druckbettgröße, was sie
gekostet hat und was ihr Betrieb kostet. Die letzten beiden lassen Khayt Ihnen
sagen, was eine Stunde auf dieser Maschine wert ist.

## Mit einem Drucker verbinden

Eine Maschine kann mit dem Drucker selbst verknüpft werden. Khayt spricht sieben
Protokolle:

- **Moonraker / Klipper** – einschließlich des Snapmaker U1.
- **OctoPrint**
- **PrusaLink**
- **Duet**
- **Repetier**
- **Bambu** – nur Status. Bambu verlangt für die Fernsteuerung inzwischen den
  eigenen Konnektor.
- **Elegoo-Harz (SDCP)**

Geben Sie die Adresse und den Schlüssel ein, drücken Sie **Testen**, und Khayt
sagt, was geantwortet hat. Der Schlüssel liegt versiegelt im Schlüsselbund des
Mac, nicht im Buch.

## Live-Status

Ein verbundener Drucker zeigt, was er druckt, wie weit er ist, die Temperaturen
und wie lange es noch dauert.

Zwei Dinge sind an dieser Anzeige wissenswert:

- **Der Fortschritt richtet sich nach Schichten, nicht nach Bytes**, wo der
  Drucker es mitteilt. Eine Byte-Position in einer Datei misst keine Arbeit – bei
  einem 31-MB-Modell zeigte die Anzeige 0,7 % an, als es fast 20 % waren.
- **Die Restzeit ist die Schätzung des Slicers**, wenn die Datei eine enthält, und
  nur dann hochgerechnet, wenn nicht.

## Ein Drucker, der umgezogen ist

Drucker bekommen neue Adressen, wenn ein Router neu startet. Khayt erkennt eine
Maschine, die es schon gesehen hat, an der eigenen Seriennummer ihrer Platine und
folgt ihr zur neuen Adresse, statt sie als offline zu zeigen.

## Ein Objekt von einer Platte streichen

Bei einem Klipper- oder Moonraker-Drucker kann ein einzelnes Objekt auf einer
Platte übersprungen werden, während der Rest der Platte weiterläuft – für das
eine Teil, das sich gelöst hat.

**Das lässt sich nicht rückgängig machen.** Klipper druckt die übersprungenen
Schichten nicht nach, wenn ein Objekt gestrichen wurde; ein versehentlich
gestrichenes Objekt ist also Ausschuss.
