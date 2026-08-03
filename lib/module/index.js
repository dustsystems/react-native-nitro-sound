"use strict";

import { NitroModules } from 'react-native-nitro-modules';
export * from "./specs/Sound.nitro.js";

// Factory: create a new HybridObject instance per call
export function createSound() {
  try {
    const inst = NitroModules.createHybridObject('Sound');

    // Proxy to bind methods to the instance
    const proxy = new Proxy(inst, {
      get(target, prop) {
        const value = target[prop];
        if (typeof value === 'function') {
          return value.bind(target);
        }
        return value;
      }
    });
    return proxy;
  } catch (error) {
    console.error('Failed to create Sound HybridObject:', error);
    throw new Error(`Failed to create Sound HybridObject: ${error}`);
  }
}

// Backward-compatible singleton (legacy API)
let _singleton = null;
const getSingleton = () => {
  if (!_singleton) {
    _singleton = createSound();
  }
  return _singleton;
};

// Proxy object that forwards to the singleton for legacy API
const Sound = new Proxy({}, {
  get(_target, prop) {
    // Ensure instance
    const inst = getSingleton();
    const value = inst[prop];
    if (typeof value === 'function') {
      return value.bind(inst);
    }
    return value;
  }
});
export default Sound;
export { Sound };
export { useSound } from "./useSound.js";
export { useSoundWithStates } from "./useSoundWithStates.js";
export { useSoundRecorder, useAudioRecorder } from "./useSoundRecorder.js";
export { useSoundRecorderWithStates, useAudioRecorderWithStates } from "./useSoundRecorderWithStates.js";
//# sourceMappingURL=index.js.map