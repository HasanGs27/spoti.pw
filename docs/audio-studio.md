# Copies vitesse et instrumentales

Le compagnon crée une nouvelle copie locale. Il conserve le fichier original, la
pochette et l’artiste ; un suffixe visible distingue le titre (`· ×1,25` ou
`· Instrumental`) et son album. Une copie validée se lit ensuite hors connexion
sur l’iPhone comme un autre fichier local. Elle n’est pas réenregistrée comme
l’enregistrement Spotify original.

La vitesse utilise FFmpeg `atempo` : ×0,75, ×1, ×1,25, ×1,5 ou ×2, avec conservation
de la hauteur. La sortie par défaut est AAC-LC stéréo à 44,1 kHz, 256 kbit/s ;
MP3 VBR est également disponible. Il s’agit d’un nouvel encodage, sans gain de
qualité par rapport à la source.

La version instrumentale utilise MelBandRoformer sur le GPU du PC. La séparation
peut laisser des restes de voix ou modifier certains instruments ; elle ne
recrée pas une piste studio officielle. Le test synthétique valide le moteur,
le format, la durée et les échantillons, pas la qualité sur chaque chanson.

## Installation Windows isolée

Prévoir au moins 15 Gio libres pendant l’installation, Python 3.12 et une carte
NVIDIA compatible avec PyTorch CUDA 12.8. Le runtime est séparé de `offline-tools`
dans `work/audio-studio` ; aucun changement de pilote système n’est effectué.
Les 62 dépendances Windows/Python 3.12 sont figées avec leurs SHA-256 dans
[`audio-studio-requirements.txt`](../scripts/audio-studio-requirements.txt).

Depuis la racine de l’espace de travail, après préparation du compagnon :

```powershell
& work/offline-tools/Scripts/python.exe -X utf8 work/spoti-local-artwork/scripts/setup_audio_studio.py --directory work/audio-studio --ffmpeg work/offline-test/profile/.spotdl/ffmpeg.exe
```

Le script télécharge les paquets et le modèle officiels, contrôle leurs empreintes,
puis sépare un signal généré de huit secondes. Il n’emploie aucune chanson de la
bibliothèque. Il écrit `config.json` avec `ready: true` seulement après réussite
du test CUDA. `--validate-only` répète cette vérification sans installation ni
téléchargement. Les chemins ci-dessus sont ceux de l’environnement compagnon ;
les arguments permettent d’utiliser d’autres chemins.

Le compagnon trouve automatiquement `work/audio-studio/config.json`. Un autre
emplacement peut être donné par `SG_AUDIO_STUDIO_CONFIG`. La vérification de
disponibilité reste légère ; le hash complet du modèle est vérifié dans le
processus de séparation avant chaque chargement.

## Versions et provenance

- `audio-separator` 0.47.0 : [projet officiel, licence MIT](https://github.com/nomadkaraoke/python-audio-separator).
- librosa 0.11.0 et audioread 3.1.0 : versions compatibles avec les imports du séparateur.
- PyTorch/torchaudio 2.8.0 CUDA 12.8 et torchvision 0.23.0 :
  [paquets officiels PyTorch](https://pytorch.org/get-started/previous-versions/).
- Modèle de KimberleyJensen / KimberleyJSN :
  [MelBandRoformer, carte du modèle MIT](https://huggingface.co/KimberleyJSN/melbandroformer).
  Le checkpoint fait 913 106 900 octets, SHA-256
  `87201f4d31afb5bc79993230fc49446918425574db48c01c405e44f365c7559e`.
- [Configuration officielle](https://github.com/KimberleyJensen/Mel-Band-Roformer-Vocal-Model/blob/main/configs/config_vocals_mel_band_roformer.yaml),
  SHA-256 `87aabb300193b019159269b69d6fe5f313aae4201a22b4af6268bc2846ab2fe1`.

Les poids ne sont pas stockés dans Git. La provenance et les versions installées
restent dans le dossier du studio. Après l’installation, la génération n’a pas
besoin d’Internet et n’effectue aucun téléchargement de modèle à la volée.

## Limites et vérification

Une seule séparation GPU fonctionne à la fois. Chaque travail instrumental est
borné à dix minutes ; il échoue clairement si le GPU ou le modèle n’est plus
disponible. Les sources acceptées sont MP3 ou M4A AAC-LC, de 1 seconde à 30 minutes,
100 Mio maximum. Le résultat est vérifié par décodage intégral : durée, absence
de NaN/Inf, codec, métadonnées, pochette et hash. L’original est contrôlé inchangé.

Les fichiers sont créés dans un sous-dossier privé unique `.audio-variants` ; les
liens symboliques et sorties hors de la racine privée sont refusés. Le manifeste
`variant.json` conserve le hash de la source, le type de transformation, les
paramètres et le hash final. Aucune suppression de l’original n’est réalisée.
