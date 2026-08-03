import { useMemo } from 'react';
import { useSoundRecorder } from './useSoundRecorder';
import type { UseSoundRecorderOptions } from './useSoundRecorder';

export type UseSoundRecorderWithStates = ReturnType<typeof useSoundRecorder>;

export function useSoundRecorderWithStates(
  options: UseSoundRecorderOptions = {}
): UseSoundRecorderWithStates {
  const base = useSoundRecorder(options);

  return useMemo(() => base, [base]);
}

// Alias
export { useSoundRecorderWithStates as useAudioRecorderWithStates };
