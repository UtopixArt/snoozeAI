// AudioDeviceType is marked experimental in audio_session but is stable in practice.
// ignore_for_file: experimental_member_use
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';

/// Shows where audio will play: a connected Bluetooth/wired device or the
/// phone speaker. Android routes there on its own; this only reports it.
class AudioOutputChip extends StatefulWidget {
  const AudioOutputChip({super.key});

  @override
  State<AudioOutputChip> createState() => _AudioOutputChipState();
}

class _AudioOutputChipState extends State<AudioOutputChip> {
  static const _external = {
    AudioDeviceType.bluetoothA2dp,
    AudioDeviceType.bluetoothLe,
    AudioDeviceType.wiredHeadset,
    AudioDeviceType.wiredHeadphones,
    AudioDeviceType.usbAudio,
  };

  AudioDevice? _device;
  StreamSubscription<Set<AudioDevice>>? _sub;

  @override
  void initState() {
    super.initState();
    AudioSession.instance.then((session) async {
      _update(await session.getDevices(includeInputs: false));
      _sub = session.devicesStream.listen(_update);
    });
  }

  void _update(Set<AudioDevice> devices) {
    if (!mounted) return;
    setState(() {
      _device = devices.where((d) => _external.contains(d.type)).firstOrNull;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
    final bluetooth = device != null &&
        (device.type == AudioDeviceType.bluetoothA2dp ||
            device.type == AudioDeviceType.bluetoothLe);
    return Chip(
      avatar: Icon(
        device == null
            ? Icons.phone_android
            : bluetooth
                ? Icons.bluetooth_audio
                : Icons.headphones,
        size: 18,
      ),
      label: Text(device == null ? 'Haut-parleur' : device.name,
          overflow: TextOverflow.ellipsis),
      visualDensity: VisualDensity.compact,
    );
  }
}
