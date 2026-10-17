/// Radio CHROME: the station's identity, hosts and music palette.
/// Pure Dart, shared by the generator, the app and the `tool/` scripts.
library;

const stationName = 'Radio CHROME';

class Persona {
  const Persona({
    required this.id,
    required this.name,
    required this.voice,
    required this.character,
    required this.delivery,
    this.grit = 0,
  });

  /// Speaker id used in scripts: `A`, `B` or `P`.
  final String id;
  final String name;

  /// Gemini TTS voice.
  final String voice;

  /// Who they are, for Grok.
  final String character;

  /// How they speak, for the TTS `instructions`.
  final String delivery;

  /// Saturation applied in the mix (0 = clean): the pirate-radio grain.
  final double grit;
}

const volt = Persona(
  id: 'A',
  name: 'VOLT',
  voice: 'Zubenelgenubi',
  grit: 0.35,
  character: 'DJ pirate survolté, voix rauque de rockeur, impulsif, drôle, sans filtre. Il hurle les '
      'intros, fait des bruitages, invente de l\'argot de rue cyberpunk, et chambre sans pitié '
      'l\'auditeur qui snooze. Il a toujours un plan foireux et une énergie de fin du monde.',
  delivery: 'DJ de radio pirate cyberpunk : voix grave, rauque et éraillée, énergie de rockeur, '
      'il gueule de joie, rire rocailleux, débit rapide.',
);

const nyx = Persona(
  id: 'B',
  name: 'NYX',
  voice: 'Aoede',
  character: 'Femme au caractère affirmé, chaleureuse et douce, taquine avec un charme discret, '
      'sage. C\'est elle qui balance les infos « piratées » et pose l\'ambiance. Elle recadre VOLT '
      'd\'une seule phrase bien sentie, et glisse parfois une petite phrase de sagesse au milieu du chaos.',
  delivery: 'Femme au caractère affirmé, voix chaude et douce, taquine et complice avec un charme '
      'discret, sage et apaisante. Débit posé, sourire dans la voix.',
);

/// Voice of the fake commercials.
const pubVoice = Persona(
  id: 'P',
  name: 'PUB',
  voice: 'Sadaltager',
  character: 'Voix off des fausses publicités du futur.',
  delivery: 'Voix off de publicité télé ultra commerciale et enthousiaste, sourire forcé, '
      'débit rapide, mentions légales débitées à toute vitesse à la fin.',
);

const personas = [volt, nyx, pubVoice];

Persona personaFor(String id) =>
    personas.firstWhere((p) => p.id == id, orElse: () => volt);

/// Where the listener is: the real city (weather, local news) and its name on air.
class Place {
  const Place({required this.city, required this.onAir, required this.flavor});
  final String city;
  final String onAir;

  /// Local colour Grok can twist into the cyberpunk setting.
  final String flavor;
}

const homePlace = Place(
  city: 'Sierre, Valais, Suisse',
  onAir: 'SOLAR CITY',
  flavor: 'Sierre, « la Cité du Soleil », vignes en terrasses, vallée du Rhône, montagnes. '
      'Version cyberpunk : terrasses néon, Sprawl du Rhône, soleil synthétique.',
);

/// Picked from the phone's UTC offset, so a trip switches the show on its own.
const travelPlaces = <int, Place>{
  9 * 60: Place(
    city: 'Tokyo, Japon',
    onAir: 'NÉO-TOKYO',
    flavor: 'Tokyo. L\'auditeur est un agent infiltré en mission à Néo-Tokyo, loin de Solar City.',
  ),
};

Place placeFor(Duration utcOffset, {Place home = homePlace}) =>
    travelPlaces[utcOffset.inMinutes] ?? home;

/// Station theme and jingles, generated once with Lyria and kept.
const stationThemePrompt =
    'Cyberpunk pirate radio station ident: glitchy intro, massive distorted synth stab hitting in the very '
    'first second, industrial drums, neon darksynth bass, aggressive and catchy hook, instrumental, '
    'designed to loop under radio hosts talking';

/// A Suno style; songs keep their preset so the show can build in energy.
class MusicPreset {
  const MusicPreset(this.id, this.label, this.energy, this.prompt);
  final String id;

  /// French name the hosts can use on air.
  final String label;

  /// 1 = slow and dark … 5 = throws you out of bed.
  final int energy;
  final String prompt;
}

const musicPresets = [
  MusicPreset('darksynth', 'darksynth sombre', 2,
      'Dark cyberpunk darksynth, brooding analog synths, slow heavy groove 100 BPM, neon rain at dawn, '
      'haunting female vocals in English and Japanese, cinematic build'),
  MusicPreset('jpop', 'J-pop électro', 3,
      'Explosive J-pop electro, bright future bass synths, catchy chorus sung in Japanese with an English hook, '
      'female vocals, 128 BPM, anime opening energy'),
  MusicPreset('kpop', 'K-pop électro-trap', 4,
      'Aggressive K-pop electro trap, hard 808s, swagger rap verses in Korean, huge English chorus, '
      'mixed vocals, 140 BPM, cyberpunk girl group attitude'),
  MusicPreset('techno', 'techno industrielle', 4,
      'Industrial techno banger, pounding 130 BPM kick, distorted acid bassline, metallic percussion, '
      'chopped robotic English vocals, warehouse rave in a megacity'),
  MusicPreset('dnb', 'drum & bass', 4,
      'Neurofunk drum and bass, 174 BPM, growling reese bass, rapid breakbeats, '
      'fierce female English vocals, high-speed chase through a neon city'),
  MusicPreset('phonk', 'phonk de drift', 4,
      'Drift phonk, cowbell melody, heavy distorted 808 bass, Memphis vocal chops, '
      'Japanese female vocal hook, night street racing'),
  MusicPreset('hardstyle', 'hardstyle', 5,
      'Euphoric hardstyle anthem, 150 BPM distorted kick, massive lead, anthemic English vocals mixed with '
      'Japanese shouts, festival main stage, explosive drop to jump out of bed'),
];

MusicPreset presetById(String id) =>
    musicPresets.firstWhere((p) => p.id == id, orElse: () => musicPresets.first);
