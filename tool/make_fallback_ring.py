# Synthesizes a soft, loopable bell arpeggio used as the offline fallback ring.
import sys, wave
import numpy as np
sr = 44100
out = np.zeros(int(sr * 6.0))
def bell(freq, start, dur=2.2, amp=0.5):
    t = np.arange(int(sr * dur)) / sr
    env = np.exp(-3.2 * t) * (1 - np.exp(-200 * t))
    tone = (np.sin(2*np.pi*freq*t) + 0.35*np.sin(2*np.pi*2*freq*t) + 0.12*np.sin(2*np.pi*3.01*freq*t))
    s = int(sr * start)
    seg = amp * env * tone
    end = min(len(out), s + len(seg))
    out[s:end] += seg[:end - s]
notes = [523.25, 659.25, 783.99, 1046.5]  # C5 E5 G5 C6
for bar in range(2):
    for i, f in enumerate(notes):
        bell(f, bar * 2.6 + i * 0.32)
out = out / np.max(np.abs(out)) * 0.9
pcm = (np.stack([out, out], axis=1) * 32767).astype(np.int16)
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes(pcm.tobytes())
