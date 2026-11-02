# Cloud-Synchronisierung

Khayt Cloud trägt Ihr Buch zwischen Rechnern und gibt Ihren Kunden eine Seite,
auf der sie ihre Bestellung verfolgen können. Sie ist optional: Die App
funktioniert vollständig ohne sie.

## Was diese App macht

- **Prüfen** – vergleicht Ihr Buch mit der Cloud und sagt, was abweicht, ohne
  etwas zu senden. Nur lesend, also unbedenklich, wenn Sie unsicher sind.
- **Senden, was nur hier ist** – schickt Ihr Buch hoch.
- **Herunterholen, was nur dort ist** – holt die Kopie der Cloud herunter und
  führt sie zusammen.

## Ihre Geheimnisse verlassen den Rechner nicht

Das Buch enthält das Cloud-Token, die API-Schlüssel der Drucker und etwaige
Speicher-Zugangsdaten. Bevor etwas gesendet wird, werden diese entfernt und durch
Platzhalter ersetzt. Die Kopie, die weggeht, enthält sie nie.

## Sperren

**Buch → Khayt Cloud sperren** beendet die automatische Synchronisierung und
vergisst den im Speicher gehaltenen Schlüssel. Das ist der Weg hinaus, und der
einzige – gut zu wissen, wenn Sie einen Mac an einem Ort lassen, den Sie nicht
kontrollieren.

## Zwei Rechner

Wenn zwei Rechner dieses Buch führen, aktualisieren Sie beide, bevor Sie sich auf
eine Synchronisierung verlassen. Ein älterer Stand kann Felder enthalten, die ein
neuerer geändert hat, und wer zuletzt schreibt, gewinnt – ein auf einer alten
Version zurückgebliebener Rechner kann also unbemerkt alte Werte wieder
einspielen.
