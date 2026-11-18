# Apps connectées

Les trancheurs qui envoient leurs fichiers tranchés directement à ce Mac, et quoi faire quand l'association ne marche pas.

## Avant de commencer

- Khayt pour Mac. L'association d'un trancheur n'existe pas dans l'app Windows ou Linux.
- Le serveur LAN allumé, avec **Écouter sur toutes les interfaces réseau (LAN)** activé, dans Réglages → En ligne. Éteint, le Mac ne répond qu'à lui-même et aucun trancheur ne peut l'atteindre.
- OrcaSlicer 2.5.1 ou plus récent avec le plugin Khayt installé, sur un ordinateur du même réseau que le Mac.
- Vous êtes le propriétaire de l'atelier ou un responsable. Les autres ne peuvent ni associer ni retirer un trancheur.

## Associer un trancheur

- Ouvrez **Apps connectées** dans la barre latérale et cliquez sur **Associer un trancheur**. Pendant les deux minutes suivantes, un trancheur de votre réseau peut demander à s'associer, et le Mac affiche l'adresse à saisir.
- Dans OrcaSlicer, ouvrez l'onglet **Khayt**, saisissez cette adresse exactement et cliquez sur **Pair**.
- Le Mac demande **Approuver « nom » ?** et indique quelle app a demandé, depuis quelle adresse. Vérifiez que c'est bien votre trancheur.
- Les deux écrans affichent un nombre à six chiffres. S'ils sont identiques, cliquez sur **Les nombres correspondent — approuver**. Le trancheur apparaît sous Trancheurs associés.

## Si les nombres diffèrent, refusez

Cliquez sur **Refuser**. Des nombres différents signifient que la demande ne vient pas directement de votre trancheur : quelque chose d'autre sur le réseau peut s'être interposé. N'approuvez pas pour voir ce qui se passe. Vérifiez que le trancheur est sur votre propre réseau et recommencez. Un clic sur Associer un trancheur permet trois essais.

## Ce qu'un trancheur associé voit, et ne voit pas

Il peut envoyer des fichiers dans la boîte Depuis votre trancheur et voir la file des travaux : numéros, étapes et machines seulement, jamais les titres ni les clients. Il voit aussi vos machines, le nom de l'atelier et le nombre de fichiers en attente. Il ne peut jamais lire votre registre, vos clients, vos prix ni vos réglages, et ne voit jamais votre code PIN LAN. Sa clé est gardée dans le trousseau de ce Mac, pas dans votre registre.

## La boîte Depuis votre trancheur

Ce qu'un trancheur envoie attend sous Depuis votre trancheur, sur l'écran Apps connectées, avec le poids et la durée calculés par le trancheur, le trancheur qui l'a envoyé et ce qu'il a demandé (un devis, une commande, une impression). Pour chaque fichier, choisissez **Ajouter à la bibliothèque**, **Nouvelle commande** ou **Nouveau devis**, ou **Écarter**. Rien ne devient une commande et aucune impression ne démarre tant que vous n'avez pas choisi : la demande du trancheur n'est qu'une suggestion. Le même fichier envoyé deux fois n'est gardé qu'une fois, et Khayt vous le dit. Jusqu'à 100 fichiers peuvent attendre. La boîte est un dossier à côté de votre registre sur ce Mac ; elle n'est ni synchronisée ni envoyée ailleurs.

## Retirer un trancheur

Sur l'écran Apps connectées, cliquez sur **Retirer…** à côté du trancheur et confirmez. Il cesse aussitôt d'envoyer à ce Mac ; pour l'utiliser de nouveau, associez-le de nouveau. Les fichiers déjà envoyés restent dans votre boîte. Changer le code PIN LAN déconnecte aussi tous les trancheurs associés, avec les téléphones associés.

## Quand l'association ne marche pas

- **Associer un trancheur est grisé :** allumez le serveur LAN et Écouter sur toutes les interfaces réseau (LAN) dans Réglages → En ligne. S'ils sont allumés, demandez au propriétaire ou à un responsable : votre rôle ne permet peut-être pas de changer les réglages.
- **Le trancheur n'atteint pas le Mac :** mettez les deux ordinateurs sur le même réseau (un Wi‑Fi invité sépare souvent les appareils), saisissez l'adresse exactement, port compris, et si le pare-feu de macOS est actif, autorisez Khayt à accepter les connexions entrantes.
- **Le trancheur dit que l'association est fermée :** elle reste ouverte deux minutes et se ferme dès qu'un trancheur est approuvé. Cliquez de nouveau sur Associer un trancheur.
- **Le code PIN LAN n'a pas pu être lu dans le trousseau :** rien n'a été associé. Définissez de nouveau le code PIN dans Réglages → En ligne, puis associez de nouveau. Cela déconnecte téléphones et trancheurs : associez-les de nouveau aussi.
- **Le trancheur dit que la boîte est pleine :** 100 fichiers attendent. Prenez-en ou écartez-en quelques-uns, puis renvoyez.
