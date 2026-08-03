"use strict";

import { useCallback, useEffect, useMemo, useRef } from 'react';
import { ensureSoundActivation } from "./utils/sound.js";
export function useSoundRecorder(options = {}) {
  const {
    autoDispose = true
  } = options;
  const soundRef = useRef(null);

  // Controls
  const startRecorder = useCallback(async (...args) => ensureSoundActivation(soundRef).startRecorder(...args), []);
  const stopRecorder = useCallback(async () => {
    const res = await ensureSoundActivation(soundRef).stopRecorder();
    return res;
  }, []);
  const mmss = useCallback(secs => ensureSoundActivation(soundRef).mmss(secs), []);
  const mmssss = useCallback(ms => ensureSoundActivation(soundRef).mmssss(ms), []);
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
  return useMemo(() => ({
    sound: ensureSoundActivation(soundRef),
    startRecorder,
    stopRecorder,
    mmss,
    mmssss,
    dispose
  }), [startRecorder, stopRecorder, mmss, mmssss, dispose]);
}

// Alias with alternative naming preference
export { useSoundRecorder as useAudioRecorder };
//# sourceMappingURL=useSoundRecorder.js.map