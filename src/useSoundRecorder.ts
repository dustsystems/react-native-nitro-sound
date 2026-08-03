import { useCallback, useEffect, useMemo, useRef } from 'react';
import type { Sound as SoundType } from './specs/Sound.nitro';
import { ensureSoundActivation } from './utils/sound';

export type UseSoundRecorderOptions = {
  autoDispose?: boolean; // default true
};

export type UseSoundRecorder = {
  sound: SoundType;
  // Recording controls
  startRecorder: SoundType['startRecorder'];
  stopRecorder: SoundType['stopRecorder'];
  // Utils
  mmss: SoundType['mmss'];
  mmssss: SoundType['mmssss'];
  // Lifecycle
  dispose: () => void;
};

export function useSoundRecorder(
  options: UseSoundRecorderOptions = {}
): UseSoundRecorder {
  const { autoDispose = true } = options;

  const soundRef = useRef<SoundType | null>(null);

  // Controls
  const startRecorder = useCallback<SoundType['startRecorder']>(
    async (...args) => ensureSoundActivation(soundRef).startRecorder(...args),
    []
  );
  const stopRecorder = useCallback<SoundType['stopRecorder']>(async () => {
    const res = await ensureSoundActivation(soundRef).stopRecorder();
    return res;
  }, []);

  const mmss = useCallback<SoundType['mmss']>(
    (secs) => ensureSoundActivation(soundRef).mmss(secs),
    []
  );
  const mmssss = useCallback<SoundType['mmssss']>(
    (ms) => ensureSoundActivation(soundRef).mmssss(ms),
    []
  );

  const dispose = useCallback(() => {
    try {
      soundRef.current?.dispose();
    } catch {}
    soundRef.current = null;
  }, []);

  useEffect(() => {
    return () => {
      if (autoDispose) dispose();
    };
  }, [autoDispose, dispose]);

  return useMemo(
    () => ({
      sound: ensureSoundActivation(soundRef),
      startRecorder,
      stopRecorder,
      mmss,
      mmssss,
      dispose,
    }),
    [
      startRecorder,
      stopRecorder,
      mmss,
      mmssss,
      dispose,
    ]
  );
}

// Alias with alternative naming preference
export { useSoundRecorder as useAudioRecorder };
