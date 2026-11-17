# Verbundene Apps

Slicer, die geslicte Dateien direkt an diesen Mac senden, und was zu tun ist, wenn das Koppeln nicht klappt.

## Bevor Sie beginnen

- Khayt für Mac. Das Koppeln eines Slicers gibt es in der Windows- oder Linux-App nicht.
- Der LAN-Server ist an, mit **Auf allen Netzwerkschnittstellen lauschen (LAN)** eingeschaltet, unter Einstellungen → Online. Aus antwortet der Mac nur sich selbst, und kein Slicer erreicht ihn.
- OrcaSlicer 2.5.1 oder neuer mit installiertem Khayt-Plugin, auf einem Computer im selben Netzwerk wie der Mac.
- Sie sind Inhaber oder Leitung der Werkstatt. Andere können keinen Slicer koppeln oder entfernen.

## Einen Slicer koppeln

- Öffnen Sie **Verbundene Apps** in der Seitenleiste und klicken Sie auf **Slicer koppeln**. In den nächsten zwei Minuten darf ein Slicer in Ihrem Netzwerk um Kopplung bitten, und der Mac zeigt die einzutippende Adresse.
- Öffnen Sie in OrcaSlicer Khayt → Pair → On this network und tippen Sie diese Adresse genau ein.
- Der Mac fragt **„Name“ zulassen?** und nennt die App und die Adresse der Anfrage. Prüfen Sie, dass es Ihr Slicer ist.
- Beide Bildschirme zeigen jetzt eine sechsstellige Zahl. Sind die Zahlen gleich, klicken Sie auf **Zahlen stimmen — zulassen**. Der Slicer erscheint unter Gekoppelte Slicer.

## Wenn die Zahlen verschieden sind, ablehnen

Klicken Sie auf **Ablehnen**. Verschiedene Zahlen bedeuten, dass die Anfrage nicht direkt von Ihrem Slicer kam; etwas anderes im Netzwerk könnte dazwischen sein. Lassen Sie sie nicht zu, um zu sehen, was passiert. Prüfen Sie, dass der Slicer in Ihrem eigenen Netzwerk ist, und koppeln Sie erneut. Ein Klick auf Slicer koppeln erlaubt drei Versuche.

## Was ein gekoppelter Slicer sieht und was nicht

Er darf Dateien in den Eingang Von Ihrem Slicer senden und die Auftragsliste sehen: nur Auftragsnummern, Stufen und Maschinen, nie Titel oder Kunden. Er sieht außerdem Ihre Maschinen, den Namen der Werkstatt und wie viele Dateien im Eingang warten. Ihr Buch, Ihre Kunden, Preise oder Einstellungen kann er nie lesen, und Ihre LAN-PIN sieht er nie. Sein Schlüssel liegt im Schlüsselbund dieses Macs, nicht in Ihrem Buch.

## Der Eingang Von Ihrem Slicer

Was ein Slicer sendet, wartet unter Von Ihrem Slicer auf dem Bildschirm Verbundene Apps, mit Gewicht und Druckzeit des Slicers, dem Slicer, der es geschickt hat, und dem, was er erbeten hat (ein Angebot, ein Auftrag, ein Druck). Wählen Sie für jede Datei **Zur Bibliothek hinzufügen**, **Neuer Auftrag** oder **Neues Angebot**, oder **Verwerfen**. Nichts wird zum Auftrag und kein Druck startet, bevor Sie wählen: Was der Slicer erbittet, ist nur ein Vorschlag. Dieselbe Datei, zweimal gesendet, wird einmal behalten, und Khayt sagt es Ihnen. Bis zu 100 Dateien können warten. Der Eingang ist ein Ordner neben Ihrem Buch auf diesem Mac; er wird weder synchronisiert noch irgendwohin gesendet.

## Einen Slicer entfernen

Klicken Sie auf dem Bildschirm Verbundene Apps neben dem Slicer auf **Entfernen…** und bestätigen Sie. Er sendet sofort nicht mehr an diesen Mac; um ihn wieder zu nutzen, koppeln Sie ihn erneut. Die Dateien, die er schon gesendet hat, bleiben in Ihrem Eingang. Eine Änderung der LAN-PIN meldet auch alle gekoppelten Slicer ab, zusammen mit den gekoppelten Telefonen.

## Wenn das Koppeln nicht klappt

- **Slicer koppeln ist ausgegraut:** Schalten Sie den LAN-Server und Auf allen Netzwerkschnittstellen lauschen (LAN) unter Einstellungen → Online ein. Sind sie an, fragen Sie den Inhaber oder die Leitung: Ihre Rolle darf Einstellungen vielleicht nicht ändern.
- **Der Slicer erreicht den Mac nicht:** Bringen Sie beide Computer ins selbe Netzwerk (ein Gast-WLAN trennt Geräte oft), tippen Sie die Adresse genau mit Port ein, und erlauben Sie Khayt bei aktiver macOS-Firewall eingehende Verbindungen.
- **Der Slicer meldet, dass das Koppeln geschlossen ist:** Es bleibt zwei Minuten offen und schließt, sobald ein Slicer zugelassen ist. Klicken Sie erneut auf Slicer koppeln.
- **Die LAN-PIN ließ sich nicht aus dem Schlüsselbund lesen:** Es wurde nichts gekoppelt. Setzen Sie die PIN unter Einstellungen → Online neu und koppeln Sie erneut. Das meldet Telefone und Slicer ab; koppeln Sie diese ebenfalls neu.
- **Der Slicer meldet einen vollen Eingang:** 100 Dateien warten. Übernehmen oder verwerfen Sie einige, dann senden Sie erneut.
