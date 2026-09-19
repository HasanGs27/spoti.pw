# Téléchargements avec le PC

Le PC prépare les fichiers ; l'iPhone les récupère et les vérifie avant d'afficher la flèche verte. Une fois les fichiers enregistrés sur l'iPhone, leur lecture hors ligne ne nécessite plus le PC.

## Utilisation

1. Démarrer le compagnon sur le PC, puis laisser le PC allumé et les deux appareils sur le même réseau local.
2. Dans **Player → Téléchargements automatiques → Options et nettoyage → Choisir PC ou iPhone**, sélectionner **Utiliser le PC associé**. Pour une première association, utiliser **Connecter le PC** avec le lien privé affiché par le compagnon.
3. Appuyer sur la flèche de la playlist et garder Spotify ouvert pendant la préparation et le transfert.
4. Consulter les titres restants dans **Téléchargements automatiques**. Une erreur peut être retentée ou complétée avec un fichier audio.

La page du compagnon affiche les demandes récentes et les fichiers prêts **sur le PC**. Ce compteur ne confirme pas leur présence sur l'iPhone : la flèche verte dans l'application sert à cela. Les commandes de nettoyage de l'application conservent les fichiers déjà téléchargés.

## Éviter et ranger les doublons sur l'iPhone

Un morceau déjà enregistré et vérifié peut être utilisé dans plusieurs sélections sans créer une nouvelle copie sur l'iPhone. Les positions et les répétitions voulues dans une playlist restent conservées : partager un fichier ne supprime pas les entrées de la playlist.

Pour les copies déjà présentes, ouvrir **Téléchargements automatiques → Options et nettoyage → Ranger les doublons**. Les copies reconnues comme doublons sont déplacées dans une archive interne ; elles ne sont pas supprimées définitivement. **Restaurer les doublons** permet de les remettre. L'archive conserve donc de l'espace occupé sur l'iPhone. Un nom de morceau identique ne suffit pas, à lui seul, à fusionner deux fichiers ou deux versions.

Après un rangement, laisser Spotify relire les fichiers locaux ; si l'ancienne liste reste affichée, fermer puis rouvrir l'application. Les fichiers déjà enregistrés restent écoutables sans le PC.

## Limites actuelles

- Aucun quota cumulatif ou journalier n'est imposé par le compagnon. La place disponible sur le PC et sur l'iPhone reste nécessaire ; les fichiers conservés sur le PC ne sont pas automatiquement purgés.
- Une sélection contient au maximum **500 entrées**, répétitions comprises. Pour une playlist plus longue, utiliser des sélections plus petites.
- Le PC accepte au maximum **10 demandes actives**, celle en cours comprise. Ce n'est pas une limite de dix playlists au total : une demande terminée libère sa place.
- Une seule playlist est préparée à la fois, avec **deux morceaux distincts en parallèle**. Un titre sans correspondance fiable est signalé en erreur ; les autres continuent.
- La préparation PC accepte des morceaux de **30 minutes maximum**, avec un fichier audio de **100 Mo maximum**. Un essai de préparation est arrêté après quatre minutes ; il peut ensuite être retenté.
- Le service d'association s'arrête au bout de **six heures** ; relancer le compagnon permet de continuer. Cela n'efface pas les fichiers enregistrés.

Ces limites décrivent notre système. Elles ne garantissent pas qu'une source externe soit disponible, ni qu'elle accepte toutes les demandes.

## Préparation

- Deux morceaux distincts sont préparés simultanément ; les playlists attendent leur tour. Chaque fichier validé est proposé au téléphone sans attendre la fin de la playlist.
- Les doublons et les copies déjà vérifiées sont réutilisés après contrôle de leur empreinte, y compris après un redémarrage du compagnon.
- Les métadonnées des morceaux sont mises en cache pendant six heures, dans une limite de 512 entrées. Les playlists sont relues pour conserver leur contenu à jour.
- La recherche contrôle le titre, les artistes, les crédits invités connus, la durée et la version. Un résultat accepté n'est plus soumis à un second rapprochement contradictoire.
- Les pochettes sont vérifiées puis intégrées au MP3. La réparation d'une pochette peut réutiliser l'audio déjà préparé et vérifié, sans nouvelle conversion.

Le MP3 utilise un débit adapté à la source disponible. Augmenter artificiellement ce débit ne restituerait pas les détails absents de la source. La disponibilité de tous les titres et la qualité du master original ne sont pas garanties. Une sélection issue d'une page Spotify publique peut être incomplète ; la liste fournie par l'application est utilisée lorsqu'elle est disponible.

## Configuration du compagnon

Installer les versions de `scripts/download-requirements.txt` dans un environnement Python dédié, avec FFmpeg et Node.js 22 ou plus récent. Le lanceur existant configure le moteur JavaScript. En démarrage manuel, définir `SG_NODE_RUNTIME` sur le chemin de Node si celui-ci n'est pas dans le `PATH`, et `SG_METADATA_CACHE_DIR` sur un dossier réservé au cache.

`scripts/automatic_downloads.py --bind <IPv4-LAN> --data <dossier-jobs> --session <session.json> --ffmpeg <chemin-ffmpeg>` conserve l'association existante. Le lien de session est privé : ne pas le publier. Le compagnon est limité au réseau local et s'arrête après six heures au maximum ; il se relance avec le même lanceur. Il ne démarre pas automatiquement avec Windows.

Le protocole reste en version 2 : les optimisations du compagnon n'exigent pas de reconstruire l'IPA compatible existante. Les commandes de rangement et de restauration sur l'iPhone nécessitent la version de l'application qui les intègre.
