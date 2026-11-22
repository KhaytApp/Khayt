# Machines et imprimantes

Ce sur quoi vous imprimez et — quand vous en connectez une — ce qu’elle fait en ce
moment.

## Ajouter une machine

Une machine est une fiche : son nom, son type, la taille de son plateau, ce
qu’elle a coûté et ce qu’elle coûte à faire tourner. Ces deux derniers permettent
à Khayt de vous dire ce que vaut une heure sur cette machine.

## Se connecter à une imprimante

Une machine peut être liée à l’imprimante elle-même. Khayt parle sept protocoles :

- **Moonraker / Klipper** — y compris le Snapmaker U1.
- **OctoPrint**
- **PrusaLink**
- **Duet**
- **Repetier**
- **Bambu** — état uniquement. Bambu exige désormais son propre connecteur pour le
  contrôle à distance.
- **Résine Elegoo (SDCP)**

Saisissez l’adresse et la clé, appuyez sur **Tester**, et Khayt dit ce qui a
répondu. La clé est scellée dans le Trousseau du Mac, pas écrite dans le livre.

## État en direct

Une imprimante connectée montre ce qu’elle imprime, l’avancement, les
températures et le temps restant.

Deux choses à savoir sur cette lecture :

- **L’avancement se mesure par couche, pas par octets** quand l’imprimante veut
  bien le dire. Une position en octets dans un fichier ne mesure pas le travail —
  un modèle de 31 Mo affichait 0,7 % alors qu’il en était presque à 20 %.
- **Le temps restant est l’estimation du slicer** quand le fichier en contient une,
  et seulement extrapolé sinon.

## Une imprimante qui a déménagé

Les imprimantes changent d’adresse quand un routeur redémarre. Khayt reconnaît une
machine déjà vue grâce au numéro de série de sa carte et la suit à sa nouvelle
adresse, au lieu de l’afficher hors ligne.

## Retirer un objet d’un plateau

Sur une imprimante Klipper ou Moonraker, un seul objet d’un plateau peut être
ignoré pendant que le reste du plateau continue — pour la pièce qui s’est
décollée.

**Cela ne peut pas être annulé.** Klipper ne réimprime pas les couches sautées
pendant qu’un objet était retiré ; un objet retiré par erreur est donc perdu.
