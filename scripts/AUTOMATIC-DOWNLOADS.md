# Téléchargements automatiques — prototype

Le téléphone envoie un lien de morceau ou de playlist au PC, qui cherche une
correspondance dans les résultats « chansons » YouTube Music. Les fichiers
acceptés sont transférés dans `Documents/Spoti Downloads` avec leur pochette.
Il ne s'agit pas du téléchargement natif Spotify Premium. La disponibilité et
la qualité de chaque source externe ne sont pas garanties. Le MP3 n'est pas
une copie sans perte ; augmenter son débit ne reconstituerait pas la source.

## PC

Python 3.11 ou plus récent et FFmpeg sont nécessaires.

```sh
python -m pip install -r scripts/download-requirements.txt
python scripts/automatic_downloads.py --bind ADRESSE_LAN_DU_PC --data downloads --ffmpeg CHEMIN_FFMPEG --session pairing.json
```

Le service écoute sur le port 8768, uniquement sur l'adresse LAN indiquée.
Il se ferme après six heures. Relancer la même commande conserve l'association
si l'adresse et le fichier `pairing.json` n'ont pas changé. Ne pas publier ce
fichier : l'adresse qu'il contient donne accès aux demandes et fichiers de ce
service. Les téléchargements interrompus par un redémarrage sont signalés.

## iPhone

1. Installer l'IPA de test, conserver les mêmes paramètres de signature.
2. Ouvrir `spoti.pw → Player → Téléchargements automatiques → Connecter le PC`.
3. Coller le lien d'association affiché par le PC et autoriser le réseau local.
4. Utiliser la flèche d'une playlist publique. Si le bouton ne reconnaît pas
   la page de cette version de Spotify, `Télécharger un lien` permet de tester
   séparément le moteur de téléchargement.
5. Garder le PC allumé, les appareils sur le même Wi-Fi et Spotify ouvert.
6. Attendre « Sur l'iPhone ». Les copies sont accessibles dans la sélection
   enregistrée et dans Fichiers locaux. L'indexation peut nécessiter d'ouvrir
   Fichiers locaux ou de relancer Spotify.

Le mode avion sert au test de lecture **après** le transfert. Le bouton
`Flèche : téléchargement via le PC` permet de revenir au comportement natif.
Les morceaux de la playlist Spotify d'origine ne sont pas redirigés vers les
copies locales : utiliser la sélection enregistrée ou Fichiers locaux.
La lecture de la sélection appelle le lecteur natif et reste à valider sur un
iPhone. Les pochettes/animations existantes ne sont pas modifiées.

## Limites et contrôles

- Maximum 500 entrées par demande et dix demandes en préparation.
- La page publique Spotify peut ne fournir qu'une partie d'une playlist. Le
  statut le dit explicitement et n'annonce pas que toute la playlist est disponible.
- Une entrée sans source conforme reste en échec. Le client ne transforme pas
  le bouton natif en faux indicateur de téléchargement réussi.
- Résultat du catalogue chansons, titre, artiste et durée sont contrôlés.
  Tolérance de durée : maximum de 2 secondes et 1,2 %. Les versions live,
  accélérées ou remixées inattendues sont rejetées. Ce n'est pas une empreinte
  acoustique et une erreur de métadonnées reste possible.
- Pochette intégrée, durée du MP3, taille et SHA-256 sont vérifiés ; l'iPhone
  valide également la présence d'une piste audio lisible avant import.
- Les requêtes sont idempotentes. Une coupure conserve les copies terminées ;
  `Reprendre` suit la même demande. `Réessayer cette sélection` en crée une nouvelle.
- Les fichiers existants ne sont pas écrasés. Un fichier modifié ou invalide
  est signalé, sans remplacement silencieux.

## Tests

```sh
# Définir SG_TEST_FFMPEG avec le chemin de FFmpeg si absent du PATH.
python scripts/test_automatic_downloads.py
```

Ces tests couvrent la sélection des sources, les URL refusées, les demandes
idempotentes, les échecs partiels, la reprise après redémarrage, le transfert
HTTP et le refus d'un fichier modifié. Le workflow macOS valide les réponses
JSON, la persistance sans valeurs nulles et les URI locales avant compilation.
Les tests n'authentifient pas une session Spotify ou YouTube et n'utilisent pas
de cookies personnels.
