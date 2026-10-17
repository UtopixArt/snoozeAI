<p align="center">
  <img src="assets/icon/logo_square.png" width="160" alt="Logo Radio CHROME : une bouche qui hurle, dents en chrome, néons magenta et cyan">
</p>

<h1 align="center">Radio CHROME</h1>

<p align="center">
  <b>Le radio-réveil pirate cyberpunk qui t'arrache du lit.</b><br>
  Chaque matin, une émission de radio unique, écrite, jouée et mixée par des IA, rien que pour toi.
</p>

---

> *« BONJOUR SOLAR CITY !!! Bzzzt ! Ici VOLT, antenne pirate de Radio CHROME, et il est sept heures pile. Si tu snoozes encore, je viens démonter ton matelas avec une clé à molette. »*
>
> *« Doucement, Volt… Le bouton snooze ne vole pas le temps. Il le déguise. »*

## Le concept

À l'heure du réveil, ce n'est pas une sonnerie qui démarre : c'est **une vraie émission de radio** d'une douzaine de minutes.

- 📡 **Un grésillement de signal pirate**, puis le générique de la station.
- 🎙️ **Deux animateurs** avec chacun sa voix et son caractère :
  - **VOLT**, DJ pirate à la voix rauque, survolté et sans filtre ;
  - **NYX**, chaleureuse, taquine et sage, qui calme le jeu d'une phrase.
- 🌦️ **La « Météo du Sprawl »** et le **« Flash corpo »** : la vraie météo et la vraie actu du jour, cherchées sur le web et racontées à la sauce cyberpunk. Les faits restent exacts.
- 🎵 **De vrais morceaux chantés**, en anglais, japonais ou coréen (darksynth, J-pop, K-pop, techno, drum & bass, phonk, hardstyle), qui montent en énergie jusqu'au dernier, celui qui te jette du lit.
- 📢 **De fausses pubs du futur**, comme l'implant SnoozeNull, qui *« coupe votre bouton snooze de l'intérieur »*.
- 😤 **Le rapport de snooze** : appuie sur snooze, et 9 minutes plus tard VOLT et NYX te tombent dessus. Ça empire à chaque snooze.

La ville a un nom de code : chez soi, Sierre devient **SOLAR CITY**, « la Cité du Soleil ». En voyage, la radio suit le fuseau horaire du téléphone, et Tokyo devient **NÉO-TOKYO**.

## Fonctionnalités

| | |
|---|---|
| ⏰ **Un réveil par jour** | une heure et un interrupteur pour chaque jour de la semaine, plus un interrupteur général |
| 🔕 **Sans réseau au réveil** | l'émission est préparée à l'avance (30 min par défaut) ; au moment de sonner, tout est déjà sur le téléphone |
| 🛟 **Toujours une sonnerie** | si la préparation échoue, le réveil joue l'émission précédente, ou une sonnerie de secours intégrée |
| 🎧 **Bluetooth automatique** | le son part sur l'enceinte ou les écouteurs connectés, sinon sur le haut-parleur |
| 📻 **La radio continue** | « Je me lève » coupe le mode alarme, mais l'émission continue dans l'app à l'endroit exact |
| 💿 **Playlist de la station** | chaque morceau payé est gardé et revient en rotation : 2 nouveaux par jour suffisent |
| ✈️ **Change de fuseau horaire** | les réveils se recalent à l'ouverture de l'app, et la radio change de ville |
| 📤 **Partage** | envoie l'émission du jour à un pote en `.m4a` (WhatsApp, Discord…) |

## Comment c'est fabriqué

```
                 30 min avant le réveil (tâche de fond Android)
 ┌──────────────────────────────────────────────────────────────────────┐
 │  Grok 4.7 + recherche web ──► conducteur JSON (répliques, pubs, snooze)│
 │  Suno v6 (en parallèle) ────► 2 nouveaux morceaux → playlist           │
 │                    │                                                   │
 │                    ▼                                                   │
 │  Gemini 3.8 Flash TTS ──► une réplique = un appel, chaque voix garantie │
 │                    │                                                   │
 │                    ▼                                                   │
 │  Mixage maison (Dart) : signal pirate, générique, voix sur fond        │
 │  musical, morceaux en fondu, jingles  ──► show.m4a + 2 versions snooze │
 └──────────────────────────────────────────────────────────────────────┘
                     À l'heure du réveil : le plugin `alarm` joue le fichier
```

| Rôle | Modèle | Via |
|---|---|---|
| Orchestrateur : script, actu, météo | `x-ai/grok-4.7`, recherche web native | OpenRouter |
| Voix de VOLT, NYX et des pubs | `google/gemini-3.8-flash-tts` (voix *Zubenelgenubi*, *Aoede*, *Sadaltager*) | OpenRouter |
| Morceaux | Suno **v6** | APIMart (revendeur, non officiel) |
| Générique de la station (généré une seule fois) | `google/lyria-3-clip-preview` | OpenRouter |
| Morceaux de secours si Suno est en panne | `google/lyria-3-pro-preview` | OpenRouter |

### Coût

Environ **0,20 à 0,35 $ par matin** (≈ 6 à 10 $ par mois) pour une émission de 12 minutes :

| Poste | Par matin |
|---|---|
| Voix (≈ 6 min de parole) | ~0,10-0,15 $ |
| Grok (script et recherche) | ~0,05-0,10 $ |
| Suno (une génération = 2 morceaux) | 0,05 $ |

Le générique ne se paie qu'une fois. La parole est le poste le plus cher : une émission plus courte coûte moins.

## Installation

### Prérequis

- **Flutter** (stable, Dart ≥ 3.13) et un **JDK 17**
- Un **SDK Android** avec la plateforme 36
- Un téléphone **Android** (testé sur Pixel 10 Pro XL)
- `ffmpeg` dans le PATH, uniquement pour les outils PC
- Une clé **[OpenRouter](https://openrouter.ai)**, et en option une clé **[APIMart](https://apimart.ai)** pour Suno

### Les clés

Crée un fichier `.env` à la racine (il est ignoré par git) :

```dotenv
OPENROUTER_API_KEY=sk-or-...
APIMART_API_KEY=...
```

Sans clé APIMart, la musique vient de la playlist déjà constituée, puis de Lyria.

### Compiler et installer

```powershell
flutter pub get
flutter test
flutter build apk --release --dart-define-from-file=.env
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

`--dart-define-from-file=.env` intègre les clés à l'APK, pour ne pas avoir à les taper sur le téléphone. Une clé saisie dans **Réglages** reste prioritaire.

> ⚠️ Avec cette option, **les clés sont lisibles dans l'APK**. C'est sans risque pour un usage perso, mais **ne partage jamais cet APK**. Pour le distribuer, compile-le sans `--dart-define-from-file` et saisis les clés dans l'app.

### Sur le téléphone

1. Accepte les **notifications**, et l'**exception d'optimisation de batterie** quand le bandeau la propose. Sans elle, Android peut couper le réseau la nuit et l'émission ne sera pas préparée.
2. Dans **⚙️ Réglages** : ton prénom, ce qui t'intéresse dans l'actu, et la ville (vraie ville + nom à l'antenne).
3. Règle **l'heure de chaque jour**, puis allume l'interrupteur **Réveil**.
4. Pour tester tout de suite : **« Préparer l'émission maintenant »** (2-3 min), puis **« Tester la sonnerie (10 s) »**, écran verrouillé.

Sur Samsung, Xiaomi, Huawei et autres surcouches agressives, voir aussi [dontkillmyapp.com](https://dontkillmyapp.com).

> ✈️ **En voyage** : après avoir changé de fuseau horaire, **ouvre l'app une fois** pour que les réveils se recalent sur l'heure locale.

## Outils PC

Pour régler les prompts et le son sans le téléphone. Les clés sont lues dans `.env`, les résultats sont écrits dans `out/` :

```powershell
# Une émission complète (Grok + voix + Suno + mixage)
dart run tool/generate_show.dart --minutes 12 --name Alex
dart run tool/generate_show.dart --tokyo            # l'épisode NÉO-TOKYO

# Seulement le script de Grok (quelques centimes, aucun audio)
dart run tool/test_script.dart

# Une génération Suno seule
dart run tool/test_suno.dart "cyberpunk hardstyle, japanese female vocals"
```

Le générique et la playlist sont gardés dans `out/station` et `out/library`, comme sur le téléphone.

## Structure du projet

```
lib/
├── main.dart                 # init, écran de sonnerie quand l'alarme démarre
├── app_store.dart            # réglages, plan de réveil par jour, clés (stockage sécurisé)
├── scheduler.dart            # programmation des réveils et de la préparation, snooze
├── screens/                  # accueil, réglages, sonnerie, lecteur « en direct »
└── services/                 # en Dart pur : tourne sur le téléphone ET sur le PC
    ├── station.dart          # identité : VOLT, NYX, villes, styles musicaux
    ├── show_generator.dart   # le chef d'orchestre de l'émission
    ├── radio_mixer.dart      # mise en ondes : générique, fond musical, jingles
    ├── audio_pcm.dart        # lecture, rééchantillonnage, écriture WAV
    ├── music_library.dart    # playlist de la station et rotation
    ├── openrouter.dart       # Grok, TTS, Lyria
    └── apimart_suno.dart     # Suno via APIMart
packages/audio_codec/         # plugin Android maison : MP3 → PCM, WAV → AAC (MediaCodec)
tool/                         # scripts PC (voir ci-dessus)
assets/                       # logo, sonnerie de secours
```

## Notes techniques

- **Pourquoi un seul fichier audio ?** Le plugin `alarm` joue un fichier, même téléphone verrouillé ou app tuée. Tout mixer à l'avance garde cette fiabilité, et ça supprime les blancs entre les rubriques.
- **Une réplique = un appel TTS.** En mode multi-voix, Gemini peut mélanger les voix et les consignes de jeu. Une voix par appel garantit que VOLT reste VOLT.
- **Grok renvoie parfois deux JSON collés** (un brouillon vide, puis le vrai). Le parseur les sépare et garde le plus complet. Si la réponse est illisible, elle est enregistrée dans `Android/data/com.snoozeai.snooze_ai/files/debug/`, lisible avec `adb`.
- **`permission_handler` est figé en 12.x.** La 13 exige la plateforme Android 37, absente du SDK utilisé ici.
- **`kotlin.incremental=false`** (dans `android/gradle.properties`) : le cache pub (C:) et le projet (D:) sont sur deux disques, ce qui casse la compilation Kotlin incrémentale sous Windows.
- **Icône** : régénérée avec `dart run flutter_launcher_icons` (config dans `pubspec.yaml`).

## Feuille de route

- [ ] Vérifier le réveil réel sur plusieurs matins (préparation en tâche de fond, snooze)
- [ ] Recaler les réveils automatiquement au changement de fuseau, sans ouvrir l'app
- [ ] Une version iPhone (AlarmKit)
- [ ] Épisodes spéciaux : week-end, anniversaire, jours fériés

---

<p align="center"><i>Radio CHROME, on coupe pas. On baisse juste assez pour que tu entendes tes propres pas.</i></p>
