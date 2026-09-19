# Téléchargements avec le PC

Le PC prépare les fichiers ; l'iPhone les récupère et les vérifie avant d'afficher la flèche verte. Une fois les fichiers enregistrés sur l'iPhone, leur lecture hors ligne ne nécessite plus le PC.

## Utilisation

1. Allumer le PC et ouvrir sa session Windows. Lorsque le démarrage automatique a été installé, le compagnon se lance discrètement ; le raccourci **Téléchargements Spotify** reste utilisable. Laisser le PC allumé et les deux appareils sur le même réseau local.
2. Dans **Player → Téléchargements automatiques → Options et nettoyage → Choisir PC ou iPhone**, sélectionner **Utiliser le PC associé**. Pour une première association, utiliser **Connecter le PC** avec le lien privé affiché par le compagnon.
3. Appuyer sur la flèche de la playlist et garder Spotify ouvert pendant la préparation et le transfert. Si le PC est absent, la demande reste enregistrée **En attente du PC** ; l’application réessaie progressivement lorsqu’elle est au premier plan.
4. Consulter les titres restants dans **Téléchargements automatiques**. Une erreur peut être retentée ou complétée avec un fichier audio.

La page du compagnon affiche les demandes récentes et les fichiers prêts **sur le PC**. Ce compteur ne confirme pas leur présence sur l'iPhone : la flèche verte dans l'application sert à cela. Les commandes de nettoyage de l'application conservent les fichiers déjà téléchargés.

## Gérer les fichiers de l’iPhone

Un morceau déjà enregistré et vérifié peut être utilisé dans plusieurs sélections sans créer une nouvelle copie sur l’iPhone. Les positions et répétitions voulues dans les playlists restent conservées.

Ouvrir **Téléchargements → Options et nettoyage → Gérer les fichiers locaux**. Cette page affiche les fichiers audio présents, y compris les anciens imports manuels. Rechercher un titre, puis toucher sa ligne ou la faire glisser vers la gauche. La confirmation **Supprimer définitivement** efface uniquement le fichier sélectionné, sans archive ni corbeille. Vérifier le nom et le dossier pour distinguer deux copies.

Toutes les playlists utilisant ce même fichier perdent cette copie hors ligne. Les autres fichiers et les playlists Spotify restent conservés. Une nouvelle demande de téléchargement explicite peut récupérer le morceau de nouveau si sa source est disponible. Le PC conserve sa propre copie préparée ; cette action libère uniquement le stockage de l’iPhone. Si Spotify affiche encore l’ancienne ligne après suppression, fermer puis rouvrir l’application. Un fichier en cours de lecture peut occuper de l’espace jusqu’à ce que le lecteur le ferme.

## Limites actuelles

- Aucun quota cumulatif ou journalier n'est imposé par le compagnon. La place disponible sur le PC et sur l'iPhone reste nécessaire ; les fichiers conservés sur le PC ne sont pas automatiquement purgés.
- Une sélection contient au maximum **500 entrées**, répétitions comprises. Pour une playlist plus longue, utiliser des sélections plus petites.
- Le PC accepte au maximum **10 demandes actives**, celle en cours comprise. Ce n'est pas une limite de dix playlists au total : une demande terminée libère sa place.
- Une seule playlist est préparée à la fois, avec **deux morceaux distincts en parallèle**. Un titre sans correspondance fiable est signalé en erreur ; les autres continuent.
- La préparation PC accepte des morceaux de **30 minutes maximum**, avec un fichier audio de **100 Mo maximum**. Un essai de préparation est arrêté après quatre minutes ; il peut ensuite être retenté.
- Le lanceur résident garde le service disponible pendant la session Windows. Le serveur lancé directement, sans ce lanceur, conserve par défaut une durée maximale de **six heures**.

Ces limites décrivent notre système. Elles ne garantissent pas qu'une source externe soit disponible, ni qu'elle accepte toutes les demandes.

## Préparation

- Deux morceaux distincts sont préparés simultanément ; les playlists attendent leur tour. Chaque fichier validé est proposé au téléphone sans attendre la fin de la playlist.
- Les doublons et les copies déjà vérifiées sont réutilisés après contrôle de leur empreinte, y compris après un redémarrage du compagnon.
- Les métadonnées des morceaux sont mises en cache pendant six heures, dans une limite de 512 entrées. Les playlists sont relues pour conserver leur contenu à jour.
- La recherche contrôle le titre, les artistes, les crédits invités connus, la durée et la version. Un résultat accepté n'est plus soumis à un second rapprochement contradictoire.
- Si une source ne peut pas être téléchargée, jusqu'à trois candidats distincts issus de YouTube Music peuvent être essayés, avec les mêmes contrôles d'identité. Il s'agit d'autres correspondances sur le même service, pas de trois fournisseurs indépendants. Aucune version approchante n'est acceptée pour remplir la liste.
- Le moteur choisit le meilleur flux audio disponible selon les informations de la source. Un flux AAC-LC compatible est conservé en M4A sans reconversion audio ; les autres flux sont convertis en MP3. La priorité reste le meilleur flux proposé, sans forcer une source AAC de qualité inférieure.
- Les pochettes sont vérifiées, mises en cache et intégrées au fichier audio. La réparation d'une pochette peut réutiliser l'audio déjà préparé et vérifié, sans nouvelle conversion.

Le MP3 utilise une compression à débit variable de haute qualité ; le fichier peut être plus volumineux qu'avec l'ancien réglage automatique. Cela ne restitue pas les détails absents de la source. Un M4A conservé évite une perte supplémentaire liée à la reconversion ; cela ne transforme pas la source en master sans perte. La disponibilité de tous les titres et la qualité du master original ne sont pas garanties. Une sélection issue d'une page Spotify publique peut être incomplète ; la liste fournie par l'application est utilisée lorsqu'elle est disponible.

## Reprendre un transfert

Avec la nouvelle version de l'application et du compagnon, une coupure du réseau ou une pause conserve la partie déjà reçue sur l'iPhone. Lors de la prochaine tentative, le transfert PC → iPhone reprend à cet endroit si le même fichier est toujours disponible. Le fichier complet est vérifié avant son import et avant l'affichage de la flèche verte.

Les transferts partiels sont temporaires : le cache est limité à 512 Mo, 32 fichiers et sept jours. iOS peut aussi le purger pour libérer de la place. Si le cache manque ou si l'ancien compagnon ne permet pas la reprise, le fichier est retransféré intégralement. Un transfert terminé quitte ce cache ; aucune deuxième copie complète n'y est conservée.

Cette reprise concerne le transfert du PC vers l'iPhone. Elle ne garantit pas la reprise au même octet d'un téléchargement depuis une source externe. Garder Spotify ouvert jusqu'à la flèche verte reste recommandé.

## Configuration du compagnon

Installer les versions de `scripts/download-requirements.txt` dans un environnement Python dédié, avec FFmpeg et Node.js 22 ou plus récent. Le lanceur existant configure le moteur JavaScript. En démarrage manuel, définir `SG_NODE_RUNTIME` sur le chemin de Node si celui-ci n'est pas dans le `PATH`, et `SG_METADATA_CACHE_DIR` sur un dossier réservé au cache.

`scripts/automatic_downloads.py --bind <IPv4-LAN> --data <dossier-jobs> --session <session.json> --ffmpeg <chemin-ffmpeg>` conserve l'association existante. Le lien de session est privé : ne pas le publier. Le serveur est limité au réseau local. Cette commande directe s'arrête par défaut après six heures ; le lanceur résident utilise `--lifetime-seconds 0` pour rester disponible pendant la session Windows. Le démarrage automatique doit être installé avec le lanceur décrit plus bas.

Le protocole reste en version 2. Le compagnon accepte les anciens fichiers MP3, conserve les associations et ajoute la prise en charge M4A ainsi que les réponses HTTP partielles. La reprise des transferts sur l'iPhone nécessite la nouvelle IPA ; les versions précédentes continuent à transférer les fichiers entiers. Le compagnon configure un cache partagé de pochettes ; un worker lancé séparément peut utiliser `SG_ARTWORK_CACHE_DIR` pour choisir ce dossier.


## Retrouver le PC et reprendre les demandes

L’association initiale reste nécessaire. Ensuite, l’application peut retrouver ce même PC si son adresse locale change, sans recopier le lien. Elle vérifie l’identité du PC avant de réutiliser la clé d’association. Autoriser **Réseau local** pour Spotify dans les réglages iOS ; les réseaux invités ou isolant les appareils peuvent empêcher la connexion.

La première demande, les sélections en attente et la pause volontaire sont conservées sur l’iPhone. La reconnexion attend progressivement jusqu’à une minute entre deux recherches et fonctionne lorsque Spotify est ouvert. Elle ne réveille pas le PC et ne lance pas l’app fermée. Une pause bloque la reprise et les transferts sur l’iPhone ; une préparation déjà reçue par le PC peut se terminer de son côté.

Le PC reprend ses préparations actives après un redémarrage. Les anciennes demandes déjà terminées ou abandonnées ne sont pas toutes relancées. Une erreur réseau temporaire peut recevoir un nouvel essai automatique ; un morceau non conforme ou introuvable n’est pas accepté pour remplir la playlist. La flèche verte confirme toujours une copie vérifiée sur l’iPhone.

La découverte utilise un service Bonjour déclaré dans l’application, en conservant les déclarations Spotify Connect existantes. Voir la [documentation Apple sur le réseau local](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

## Actualiser une playlist

Dans les options de la sélection, **Mettre à jour la sélection** relit la playlist. Les copies déjà disponibles sont réutilisées et les nouveaux titres sont préparés. Aucun ancien fichier audio n’est supprimé automatiquement si un morceau disparaît de la playlist Spotify. La liste publique accessible peut être incomplète ; ce cas reste affiché dans l’app.

## Choisir une autre version

Dans la liste des téléchargements, faire glisser vers la gauche un morceau téléchargé puis choisir **Changer de version**. Cette action demande au PC une autre source conforme du morceau, puis propose une préécoute avant **Utiliser cette version**. Avant cette confirmation, refuser ou annuler conserve la copie actuelle. Après confirmation et vérification, les sélections locales utilisent la version choisie ; cette préférence est aussi mémorisée sur le PC. Si la connexion se coupe pendant la confirmation, l'application vérifie son résultat à la reconnexion.

Spotify identifie les fichiers locaux avec leurs tags. Pour distinguer deux versions, l’album de la nouvelle copie reçoit un repère **Version 2**, **Version 3**, etc. Le titre, l’artiste et la pochette sont conservés ; ce repère n’ajoute pas de conversion audio. L’ancien fichier reste disponible et peut être supprimé séparément dans **Gérer les fichiers locaux**. Il occupe encore de la place tant qu’il n’est pas supprimé.

Les recherches alternatives utilisent les mêmes contrôles de titre, artistes, version et durée. Elles restent limitées aux sources fiables trouvées par le moteur ; une autre version, un meilleur enregistrement ou tous les titres du catalogue ne sont pas garantis.

## Stockage du PC

Les nouvelles préparations partagent un fichier audio vérifié plutôt que de le recopier pour chaque playlist. Les anciens dossiers sont conservés au premier lancement de cette mise à jour.

Ouvrir **Options et nettoyage → Stockage du PC**. Son nettoyage explicite consolide les anciennes copies vérifiées, puis enlève les fichiers devenus inutilisés et suffisamment anciens. Les fichiers nécessaires aux téléchargements prêts et à la version choisie restent disponibles. Un historique incohérent ou une préparation active bloque le nettoyage plutôt que de deviner quels fichiers effacer. Cette action ne supprime rien sur l'iPhone.

## Installation du démarrage Windows

Le lanceur `scripts/pc_companion_launcher.py` utilise un dossier d’association existant : il ne crée pas de nouvelle clé. L’option `--startup-enable` installe une entrée de démarrage pour cette installation ; `--startup-disable` enlève uniquement cette entrée. `--check --json` affiche un diagnostic sans clé ni lien privé. Le raccourci habituel du bureau continue à fonctionner.

Le mode résident attend le réseau au démarrage et relance uniquement son propre processus serveur si nécessaire. Il n’allume pas un PC arrêté et n’empêche pas sa mise en veille. Les fichiers déjà téléchargés sur l’iPhone restent utilisables lorsque le PC est éteint.
