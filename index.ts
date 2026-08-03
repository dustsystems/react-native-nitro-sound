// Re-export types and interfaces from the nitro module
export * from './src/specs/Sound.nitro';

// Export specific types that exist in Sound.nitro.ts
export type {
  RecordBackType,
  PlayBackType,
  PlaybackEndType,
  RecordBackListener,
  PlayBackListener,
  PlaybackEndListener,
  Sound,
} from './src/specs/Sound.nitro';

// Export Android enums that exist in Sound.nitro.ts
export {
  AudioSourceAndroidType,
  OutputFormatAndroidType,
  AudioEncoderAndroidType,
} from './src/specs/Sound.nitro';
