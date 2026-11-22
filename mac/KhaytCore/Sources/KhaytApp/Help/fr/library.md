# La bibliothèque de modèles

Chaque modèle que vous imprimez, avec son image, sa matière et ce qu’il coûte à
produire.

## Faire entrer des modèles

Trois voies d’entrée, identiques au fond :

- Le bouton **Importer des modèles** de la bibliothèque.
- Faire glisser des fichiers ou des dossiers entiers sur la bibliothèque.
- **Livre → Ajouter un modèle**, ou ⇧⌘I.

Les dossiers sont parcourus, vous pouvez donc pointer Khayt sur un téléchargement
et le laisser trouver les modèles à l’intérieur. Tout ce qui n’est pas un modèle
est ignoré en silence.

## Les dossiers deviennent des groupes

**Le dossier d’où vient un modèle devient le groupe dans lequel il est classé.**
Un téléchargement de sept modèles dans sept dossiers arrive en sept groupes, pas
en un tas à plat.

Les dossiers d’emballage sont traversés. Un modèle situé à

`Saudi Kings/King Abdulaziz/STL/presupported/crown.stl`

est classé sous **King Abdulaziz** — pas sous *presupported*, *STL* ou *files*,
car ceux-ci décrivent le fichier au lieu de nommer la chose.

Un fichier choisi seul n’est pas groupé. Un fichier ne fait pas un ensemble.

## Doublons

Un modèle que vous avez déjà est reconnu au contenu du fichier, pas à son nom, et
refusé plutôt qu’ajouté deux fois. Renommer un fichier ne le trompe pas ;
réexporter le même modèle depuis un slicer change généralement les octets, et il
s’agit alors réellement d’un nouveau fichier.

## Regarder les modèles

La bibliothèque est une grille parce qu’un atelier d’impression reconnaît un
modèle en le regardant. La barre d’espace ouvre l’Aperçu rapide, comme dans le
Finder. Les flèches parcourent la grille, et dans une fenêtre arabe elles la
parcourent dans le bon sens.
