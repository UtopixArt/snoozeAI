import 'package:flutter/material.dart';

import '../app_store.dart';
import '../services/show_config.dart';
import '../services/station.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _apiKey = TextEditingController();
  final _sunoKey = TextEditingController();
  final _name = TextEditingController();
  final _city = TextEditingController();
  final _onAirCity = TextEditingController();
  final _interests = TextEditingController();
  final _musicStyle = TextEditingController();
  final _grokModel = TextEditingController();
  final _ttsModel = TextEditingController();

  ShowConfig _config = const ShowConfig();
  AlarmPlan _plan = const AlarmPlan();
  bool _loaded = false;
  bool _showKeys = false;

  List<TextEditingController> get _controllers => [
        _apiKey, _sunoKey, _name, _city, _onAirCity, _interests, _musicStyle, _grokModel, _ttsModel,
      ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _config = await AppStore.loadConfig();
    _plan = await AppStore.loadPlan();
    _apiKey.text = await AppStore.loadApiKey() ?? '';
    _sunoKey.text = await AppStore.loadSunoKey() ?? '';
    _name.text = _config.listenerName;
    _city.text = _config.city;
    _onAirCity.text = _config.onAirCity;
    _interests.text = _config.interests;
    _musicStyle.text = _config.musicStyle;
    _grokModel.text = _config.grokModel;
    _ttsModel.text = _config.ttsModel;
    setState(() => _loaded = true);
  }

  Future<void> _save() async {
    await AppStore.saveApiKey(_apiKey.text.trim());
    await AppStore.saveSunoKey(_sunoKey.text.trim());
    await AppStore.saveConfig(_config.copyWith(
      listenerName: _name.text.trim(),
      city: _city.text.trim(),
      onAirCity: _onAirCity.text.trim().toUpperCase(),
      interests: _interests.text.trim(),
      musicStyle: _musicStyle.text.trim(),
      grokModel: _grokModel.text.trim(),
      ttsModel: _ttsModel.text.trim(),
    ));
    await AppStore.savePlan(_plan);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _keyField(TextEditingController c, String label, String hint) => TextField(
        controller: c,
        obscureText: !_showKeys,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          suffixIcon: IconButton(
            icon: Icon(_showKeys ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showKeys = !_showKeys),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Réglages'),
        actions: [TextButton(onPressed: _loaded ? _save : null, child: const Text('Enregistrer'))],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Clés API', style: theme.textTheme.titleMedium),
                _keyField(_apiKey, 'OpenRouter (Grok, voix, générique)', 'sk-or-…'),
                _keyField(_sunoKey, 'APIMart (musique Suno)', 'vide = playlist + Lyria'),
                const SizedBox(height: 24),
                Text('Toi', style: theme.textTheme.titleMedium),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Ton prénom (VOLT et NYX t\'appellent comme ça)'),
                ),
                TextField(
                  controller: _interests,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Ce qui t\'intéresse dans l\'actu',
                    hintText: 'tech, IA, jeux vidéo, foot…',
                  ),
                ),
                const SizedBox(height: 24),
                Text('La ville', style: theme.textTheme.titleMedium),
                TextField(
                  controller: _city,
                  decoration: const InputDecoration(labelText: 'Ta vraie ville (météo, infos locales)'),
                ),
                TextField(
                  controller: _onAirCity,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Son nom à l\'antenne'),
                ),
                const SizedBox(height: 6),
                Text(
                  'En voyage, la radio change toute seule selon le fuseau horaire du téléphone : '
                  '${travelPlaces.values.map((p) => '${p.onAir} (${p.city})').join(', ')}.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                Text('L\'émission', style: theme.textTheme.titleMedium),
                Text("Durée : ${_config.showMinutes} min "
                    '(${_config.songCount} morceau${_config.songCount > 1 ? 'x' : ''})'),
                Slider(
                  value: _config.showMinutes.toDouble(),
                  min: 6,
                  max: 30,
                  divisions: 12,
                  label: '${_config.showMinutes} min',
                  onChanged: (v) => setState(() => _config = _config.copyWith(showMinutes: v.round())),
                ),
                DropdownButtonFormField<int>(
                  initialValue: const [60, 90, 120, 150, 240].contains(_config.songSeconds)
                      ? _config.songSeconds
                      : 120,
                  decoration: const InputDecoration(labelText: 'Durée max par morceau'),
                  items: const [
                    DropdownMenuItem(value: 60, child: Text('1 min')),
                    DropdownMenuItem(value: 90, child: Text('1 min 30')),
                    DropdownMenuItem(value: 120, child: Text('2 min')),
                    DropdownMenuItem(value: 150, child: Text('2 min 30')),
                    DropdownMenuItem(value: 240, child: Text('Morceau complet')),
                  ],
                  onChanged: (v) => setState(() => _config = _config.copyWith(songSeconds: v)),
                ),
                TextField(
                  controller: _musicStyle,
                  decoration: const InputDecoration(
                    labelText: 'Envie musicale en plus (optionnel)',
                    hintText: 'ex. plus de voix japonaises, plus brutal…',
                  ),
                ),
                DropdownButtonFormField<int>(
                  initialValue: _plan.leadMinutes,
                  decoration: const InputDecoration(labelText: 'Préparer l\'émission'),
                  items: [
                    for (final m in const [15, 30, 45, 60, 90])
                      DropdownMenuItem(value: m, child: Text('$m min avant le réveil')),
                  ],
                  onChanged: (v) => setState(() => _plan = _plan.copyWith(leadMinutes: v)),
                ),
                const SizedBox(height: 24),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Modèles avancés'),
                  children: [
                    TextField(
                      controller: _grokModel,
                      decoration: const InputDecoration(labelText: 'Orchestrateur (OpenRouter)'),
                    ),
                    TextField(
                      controller: _ttsModel,
                      decoration: const InputDecoration(labelText: 'Voix (OpenRouter)'),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
