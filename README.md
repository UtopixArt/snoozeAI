<p align="center">
  <img src="assets/icon/logo_square.png" width="160" alt="Radio CHROME logo: a screaming mouth with chrome teeth, magenta and cyan neon">
</p>

<h1 align="center">Radio CHROME</h1>

<p align="center">
  <b>The cyberpunk pirate radio alarm clock that drags you out of bed.</b><br>
  Every morning, a one-off radio show written, performed and mixed by AI, just for you.
</p>

---

> *« BONJOUR SOLAR CITY !!! Bzzzt ! Ici VOLT, antenne pirate de Radio CHROME, et il est sept heures pile. Si tu snoozes encore, je viens démonter ton matelas avec une clé à molette. »*
> — "GOOD MORNING SOLAR CITY!!! This is VOLT, pirate frequency of Radio CHROME, it's seven sharp. Hit snooze again and I'm coming to take your mattress apart with a wrench."
>
> *« Doucement, Volt… Le bouton snooze ne vole pas le temps. Il le déguise. »*
> — "Easy, Volt… The snooze button doesn't steal time. It disguises it."

The show is in French (the app was made for a French-speaking listener); the code and docs are in English.

## The idea

When the alarm goes off, you don't get a ringtone: you get **a real radio show** of about twelve minutes.

- 📡 **Pirate signal static**, then the station theme.
- 🎙️ **Two hosts**, each with their own voice and personality:
  - **VOLT**, a raspy, hyperactive, unfiltered pirate DJ;
  - **NYX**, warm, teasing and wise, who settles things down in one line.
- 🌦️ **"Sprawl Weather"** and the **"Corpo Flash"**: today's real weather and real news, found on the web and told cyberpunk-style. The facts stay accurate.
- 🎵 **Real songs with vocals** in English, Japanese or Korean (darksynth, J-pop, K-pop, techno, drum & bass, phonk, hardstyle), building up in energy until the last one throws you out of bed.
- 📢 **Fake ads from the future**, like the SnoozeNull implant that "cuts off your snooze button from the inside".
- 😤 **The snooze report**: hit snooze and 9 minutes later VOLT and NYX come down on you. It gets worse every time.

The city gets a code name: at home, Sierre (Switzerland's "City of the Sun") becomes **SOLAR CITY**. On a trip, the radio follows the phone's time zone, and Tokyo becomes **NÉO-TOKYO**.

## Features

| | |
|---|---|
| ⏰ **One alarm per day** | a time and an on/off switch for each day of the week, plus a master switch |
| 🔕 **No network needed at ring time** | the show is prepared ahead of time (30 min by default); when the alarm rings, everything is already on the phone |
| 🛟 **Always rings** | if preparation fails, the alarm plays the previous show, or a bundled fallback ring |
| 🎧 **Automatic Bluetooth** | sound goes to the connected speaker or earbuds, otherwise the phone speaker |
| 📻 **The radio keeps going** | "I'm up" stops the alarm, but the show carries on in the app from the exact same spot |
| 💿 **Station playlist** | every paid-for song is kept and rotated back in: 2 new ones a day is enough |
| ✈️ **Time-zone aware** | alarms re-align when the app opens, and the radio switches city |
| 📤 **Sharing** | send today's show to a friend as an `.m4a` (WhatsApp, Discord…) |

## How it's made

```
                 30 min before the alarm (Android background job)
 ┌───────────────────────────────────────────────────────────────────────┐
 │  Grok 4.7 + web search ──► JSON rundown (lines, ads, snooze roasts)   │
 │  Suno v6 (in parallel) ──► 2 new songs → station playlist             │
 │                    │                                                  │
 │                    ▼                                                  │
 │  Gemini 3.8 Flash TTS ──► one call per line, each voice guaranteed    │
 │                    │                                                  │
 │                    ▼                                                  │
 │  Custom mixer (Dart): pirate static, theme, voices over a music bed,  │
 │  songs with fades, jingles ──► show.m4a + 2 snooze versions           │
 └───────────────────────────────────────────────────────────────────────┘
                     At ring time: the `alarm` plugin plays the file
```

| Role | Model | Through |
|---|---|---|
| Orchestrator: script, news, weather | `x-ai/grok-4.7` with native web search | OpenRouter |
| Voices of VOLT, NYX and the ads | `google/gemini-3.8-flash-tts` (voices *Zubenelgenubi*, *Aoede*, *Sadaltager*) | OpenRouter |
| Songs | Suno **v6** | APIMart (unofficial reseller) |
| Station theme (generated once) | `google/lyria-3-clip-preview` | OpenRouter |
| Fallback songs when Suno is down | `google/lyria-3-pro-preview` | OpenRouter |

### Cost

About **$0.20–0.35 per morning** (≈ $6–10 a month) for a 12-minute show:

| Item | Per morning |
|---|---|
| Voices (≈ 6 min of speech) | ~$0.10–0.15 |
| Grok (script and search) | ~$0.05–0.10 |
| Suno (one generation = 2 songs) | $0.05 |

The theme is paid for once. Speech is the most expensive part: a shorter show costs less.

## Setup

### Requirements

- **Flutter** (stable, Dart ≥ 3.13) and a **JDK 17**
- An **Android SDK** with platform 36
- An **Android** phone (tested on a Pixel 10 Pro XL)
- `ffmpeg` on the PATH, for the PC tools only
- An **[OpenRouter](https://openrouter.ai)** key, and optionally an **[APIMart](https://apimart.ai)** key for Suno

### Keys

Create a `.env` file at the project root (git ignores it):

```dotenv
OPENROUTER_API_KEY=sk-or-...
APIMART_API_KEY=...
```

Without an APIMart key, music comes from the existing playlist, then from Lyria.

### Build and install

```powershell
flutter pub get
flutter test
flutter build apk --release --dart-define-from-file=.env
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

`--dart-define-from-file=.env` bakes the keys into the APK so you don't have to type them on the phone. A key entered in **Réglages** (Settings) takes precedence.

> ⚠️ With this option, **the keys can be read from the APK**. That's fine for personal use, but **never share that APK**. To distribute the app, build it without `--dart-define-from-file` and enter the keys in the app.

### On the phone

1. Allow **notifications**, and the **battery optimization exemption** when the banner offers it. Without it, Android may cut network access overnight and the show won't be prepared.
2. In **⚙️ Réglages** (Settings): your first name, what you care about in the news, and the city (real city + on-air name).
3. Set **each day's time**, then turn on the **Réveil** (Alarm) switch.
4. To test right away: **"Préparer l'émission maintenant"** (prepare the show now, 2–3 min), then **"Tester la sonnerie (10 s)"** (test ring) with the screen locked.

On Samsung, Xiaomi, Huawei and other aggressive Android skins, see also [dontkillmyapp.com](https://dontkillmyapp.com).

> ✈️ **Traveling**: after changing time zones, **open the app once** so the alarms re-align to local time.

## PC tools

To tune prompts and sound without the phone. Keys are read from `.env`, results go to `out/`:

```powershell
# A full show (Grok + voices + Suno + mix)
dart run tool/generate_show.dart --minutes 12 --name Alex
dart run tool/generate_show.dart --tokyo            # the NÉO-TOKYO episode

# Grok's script only (a few cents, no audio)
dart run tool/test_script.dart

# A single Suno generation
dart run tool/test_suno.dart "cyberpunk hardstyle, japanese female vocals"
```

The theme and the playlist persist in `out/station` and `out/library`, just like on the phone.

## Project layout

```
lib/
├── main.dart                 # init, ring screen when the alarm starts
├── app_store.dart            # settings, per-day alarm plan, keys (secure storage)
├── scheduler.dart            # alarm and pre-wake job scheduling, snooze
├── screens/                  # home, settings, ring, "live" player
└── services/                 # pure Dart: runs on the phone AND on the PC
    ├── station.dart          # identity: VOLT, NYX, cities, music styles
    ├── show_generator.dart   # the show's conductor
    ├── radio_mixer.dart      # on-air layout: theme, music bed, jingles
    ├── audio_pcm.dart        # decoding, resampling, WAV writing
    ├── music_library.dart    # station playlist and rotation
    ├── openrouter.dart       # Grok, TTS, Lyria
    └── apimart_suno.dart     # Suno through APIMart
packages/audio_codec/         # in-house Android plugin: MP3 → PCM, WAV → AAC (MediaCodec)
tool/                         # PC scripts (see above)
assets/                       # logo, fallback ring
```

## Technical notes

- **Why a single audio file?** The `alarm` plugin plays one file, even with the phone locked or the app killed. Mixing everything ahead of time keeps that reliability, and removes gaps between segments.
- **One TTS call per line.** In multi-speaker mode, Gemini can blend voices and acting directions. One voice per call guarantees VOLT stays VOLT.
- **Grok sometimes returns two JSON objects back to back** (an empty draft, then the real one). The parser splits them and keeps the most complete. An unreadable answer is saved to `Android/data/com.snoozeai.snooze_ai/files/debug/`, readable over `adb`.
- **`permission_handler` is pinned to 12.x.** Version 13 requires Android platform 37, which the SDK used here lacks.
- **`kotlin.incremental=false`** (in `android/gradle.properties`): the pub cache (C:) and the project (D:) sit on different drives, which breaks incremental Kotlin builds on Windows.
- **Icon**: regenerate with `dart run flutter_launcher_icons` (config in `pubspec.yaml`).

## Roadmap

- [ ] Check real wake-ups over several mornings (background preparation, snooze)
- [ ] Re-align alarms automatically on time-zone change, without opening the app
- [ ] An iPhone version (AlarmKit)
- [ ] Special episodes: weekends, birthdays, public holidays

---

<p align="center"><i>« Radio CHROME, on coupe pas. On baisse juste assez pour que tu entendes tes propres pas. »</i><br>
"Radio CHROME never cuts out. We just turn it down enough for you to hear your own footsteps."</p>
