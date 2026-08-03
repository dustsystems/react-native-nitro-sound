import type { UseSound, UseSoundOptions } from './useSound';
export type UseSoundWithStatesState = {
    isRecording: boolean;
    isPlaying: boolean;
    playback: {
        position: number;
        duration: number;
    };
};
export type UseSoundWithStates = Omit<UseSound, 'state'> & {
    state: UseSoundWithStatesState;
};
export declare function useSoundWithStates(options?: UseSoundOptions): UseSoundWithStates;
//# sourceMappingURL=useSoundWithStates.d.ts.map