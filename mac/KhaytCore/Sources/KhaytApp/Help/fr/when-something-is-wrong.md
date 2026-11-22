# Quand quelque chose ne va pas

## « Ouvert en lecture seule »

Khayt pour Windows et Linux a le livre ouvert, ou un autre Mac. Une seule app
écrit un livre à la fois, exprès : deux en même temps, c’est ainsi que le travail
d’un après-midi disparaît. Fermez-le là-bas et utilisez **Livre → Recharger depuis
le disque**.

## Un chiffre ici ne correspond pas à l’autre app

Ce ne devrait pas être le cas — les deux calculent d’après les mêmes règles
partagées. Deux choses donnent l’impression d’un désaccord :

- **Les livres sont différents.** Vérifiez le nom en haut à gauche ; un livre de
  développement et un livre livré sont deux fichiers différents.
- **L’un est périmé.** **Livre → Recharger depuis le disque** après que l’autre app
  a écrit.

Si le désaccord persiste, il vaut la peine d’être signalé, avec les deux chiffres.

## L’imprimante ne dit rien

- Vérifiez l’adresse et la clé avec **Tester** sur la machine.
- Une imprimante qui a changé d’adresse est généralement suivie automatiquement,
  mais seulement une fois que Khayt a vu son numéro de série — une imprimante qu’il
  n’a jamais atteinte ne peut pas être reconnue plus tard.
- Les imprimantes Bambu ne rapportent que leur état. Le contrôle à distance exige le
  connecteur propre à Bambu.

## Un modèle ne s’importe pas

- Il est peut-être déjà là. Khayt reconnaît un fichier à son contenu, pas à son
  nom, et refuse un doublon.
- Seuls les fichiers de modèle et de G-code sont pris ; tout le reste d’un dossier
  est ignoré.
- Importer le dossier de votre propre bibliothèque dans lui-même ne fait rien, exprès.

## Obtenir un build qui fonctionne

**Khayt → Rechercher des mises à jour…**. Si l’app ne démarre pas du tout, aucune
mise à jour ne peut vous atteindre — Sparkle s’exécute dans l’app — et le build
doit être téléchargé à la main depuis la page des versions.
