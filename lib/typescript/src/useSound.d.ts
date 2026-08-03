import type { Sound as SoundType, PlayBackType } from './specs/Sound.nitro';
export type UseSoundOptions = {
    autoDispose?: boolean;
    onPlayback?: (e: PlayBackType & {
        ended?: boolean;
    }) => void;
    onPlaybackEnd?: (e: {
        duration: number;
        currentPosition: number;
    }) => void;
};
export type UseSoundState = {
    isRecording: boolean;
    isPlaying: boolean;
    duration: number;
    currentPosition: number;
};
export type UseSound = {
    sound: SoundType;
    state: UseSoundState;
    startRecorder: SoundType['startRecorder'];
    stopRecorder: SoundType['stopRecorder'];
    startPlayer: SoundType['startPlayer'];
    pausePlayer: SoundType['pausePlayer'];
    resumePlayer: SoundType['resumePlayer'];
    stopPlayer: SoundType['stopPlayer'];
    seekToPlayer: SoundType['seekToPlayer'];
    setVolume: SoundType['setVolume'];
    dispose: () => void;
};
export declare function useSound(options?: UseSoundOptions): UseSound;
//# sourceMappingURL=useSound.d.ts.map