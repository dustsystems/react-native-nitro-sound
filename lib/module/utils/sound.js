"use strict";

import { createSound } from '../index';

// Ensures a Sound HybridObject exists in the given ref.
// Recreates it if previously disposed (ref.current === null).
export function ensureSoundActivation(ref) {
  if (!ref.current) {
    ref.current = createSound();
  }
  return ref.current;
}
//# sourceMappingURL=sound.js.map