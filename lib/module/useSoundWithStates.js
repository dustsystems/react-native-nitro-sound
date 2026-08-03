"use strict";

import { useMemo, useState } from 'react';
import { useSound } from "./useSound.js";
export function useSoundWithStates(options = {}) {
  const [state, setState] = useState({
    isRecording: false,
    isPlaying: false,
    playback: {
      position: 0,
      duration: 0
    }
  });
  const base = useSound({
    ...options,
    onPlayback: e => {
      options.onPlayback?.(e);
      const ended = e.ended || e.duration > 0 && e.currentPosition >= e.duration;
      const position = Math.min(e.currentPosition ?? 0, e.duration ?? Number.MAX_SAFE_INTEGER);
      setState(s => ({
        ...s,
        isPlaying: !ended,
        playback: {
          position,
          duration: e.duration ?? s.playback.duration
        }
      }));
    },
    onPlaybackEnd: e => {
      options.onPlaybackEnd?.(e);
      setState(s => ({
        ...s,
        isPlaying: false,
        playback: {
          position: e.currentPosition,
          duration: e.duration
        }
      }));
    }
  });

  // Wrap base controls to keep local state consistent even if native doesn't emit an event.
  const startPlayer = useMemo(() => async (...args) => {
    const res = await base.startPlayer(...args);
    setState(s => ({
      ...s,
      isPlaying: true
    }));
    return res;
  }, [base]);
  const pausePlayer = useMemo(() => async () => {
    const res = await base.pausePlayer();
    setState(s => ({
      ...s,
      isPlaying: false
    }));
    return res;
  }, [base]);
  const resumePlayer = useMemo(() => async () => {
    const res = await base.resumePlayer();
    setState(s => ({
      ...s,
      isPlaying: true
    }));
    return res;
  }, [base]);
  const stopPlayer = useMemo(() => async () => {
    const res = await base.stopPlayer();
    setState(s => ({
      ...s,
      isPlaying: false,
      playback: {
        position: 0,
        duration: s.playback.duration
      }
    }));
    return res;
  }, [base]);
  const seekToPlayer = useMemo(() => async t => {
    const res = await base.seekToPlayer(t);
    setState(s => ({
      ...s,
      playback: {
        ...s.playback,
        position: t
      }
    }));
    return res;
  }, [base]);
  return useMemo(() => ({
    ...base,
    startPlayer,
    pausePlayer,
    resumePlayer,
    stopPlayer,
    seekToPlayer,
    state
  }), [base, startPlayer, pausePlayer, resumePlayer, stopPlayer, seekToPlayer, state]);
}
//# sourceMappingURL=useSoundWithStates.js.map