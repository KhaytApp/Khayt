# Synchronisation cloud

Khayt Cloud transporte votre livre d’une machine à l’autre et donne à vos clients
une page pour suivre leur commande. C’est facultatif : l’app fonctionne
parfaitement sans.

## Ce que fait cette app

- **Vérifier** — compare votre livre au cloud et dit ce qui diffère, sans rien
  envoyer. En lecture seule, donc sans risque quand vous avez un doute.
- **Envoyer ce qui n’existe qu’ici** — envoie votre livre.
- **Récupérer ce qui n’existe que là-bas** — rapatrie la copie du cloud et la
  fusionne.

## Vos secrets ne sortent pas

Le livre contient le jeton cloud, les clés d’API des imprimantes et les secrets de
stockage éventuels. Avant tout envoi, ils sont retirés et remplacés par des
masques. La copie qui sort ne les contient jamais.

## Verrouillage

**Livre → Verrouiller Khayt Cloud** met fin à la synchronisation automatique et
oublie la clé conservée en mémoire. C’est la voie de sortie, et la seule — bon à
savoir si vous laissez un Mac quelque part que vous ne contrôlez pas.

## Deux machines

Si deux machines tiennent ce livre, mettez-les toutes deux à jour avant de vous
fier à une synchronisation. Une version plus ancienne peut porter des champs
qu’une plus récente a modifiés, et la dernière à écrire l’emporte — une machine
restée sur une ancienne version peut donc remettre discrètement d’anciennes
valeurs.
