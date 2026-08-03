"use strict";

import { useMemo } from 'react';
import { useSoundRecorder } from "./useSoundRecorder.js";
export function useSoundRecorderWithStates(options = {}) {
  const base = useSoundRecorder(options);
  return useMemo(() => base, [base]);
}

// Alias
export { useSoundRecorderWithStates as useAudioRecorderWithStates };
//# sourceMappingURL=useSoundRecorderWithStates.js.map