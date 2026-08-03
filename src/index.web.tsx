import type { Sound } from './specs/Sound.nitro';

// Export an empty object typed as Sound.
// This satisfies TypeScript and bundlers without manual upkeep.
const SoundWebImpl: Sound = {} as Sound;

export default SoundWebImpl;