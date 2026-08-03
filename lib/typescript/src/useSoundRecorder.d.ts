import type { Sound as SoundType } from './specs/Sound.nitro';
export type UseSoundRecorderOptions = {
    autoDispose?: boolean;
};
export type UseSoundRecorder = {
    sound: SoundType;
    startRecorder: SoundType['startRecorder'];
    stopRecorder: SoundType['stopRecorder'];
    mmss: SoundType['mmss'];
    mmssss: SoundType['mmssss'];
    dispose: () => void;
};
export declare function useSoundRecorder(options?: UseSoundRecorderOptions): UseSoundRecorder;
export { useSoundRecorder as useAudioRecorder };
//# sourceMappingURL=useSoundRecorder.d.ts.map