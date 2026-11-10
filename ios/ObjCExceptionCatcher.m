#import "ObjCExceptionCatcher.h"

NSString *const ObjCExceptionCatcherErrorDomain = @"ObjCException";

@implementation ObjCExceptionCatcher

+ (BOOL)reconnectPlayers:(NSArray<AVAudioPlayerNode *> *)players
                   engine:(AVAudioEngine *)engine
                    error:(NSError **)error {
    @try {
        // If the engine is already running (e.g. some other path started it after a prior
        // recovery attempt failed mid-reconnect, leaving a dangling player node) it must be
        // stopped before the graph can be safely re-stamped — done here, inside the same
        // @try, so a stop-time exception is caught too (DUS-1714 review).
        if (engine.isRunning) {
            [engine stop];
        }
        for (AVAudioPlayerNode *player in players) {
            [engine disconnectNodeOutput:player];
            [engine connect:player to:engine.mainMixerNode format:nil];
        }
        [engine prepare];
        NSError *startError = nil;
        BOOL started = [engine startAndReturnError:&startError];
        if (!started) {
            if (error) {
                *error = startError ?: [NSError errorWithDomain:@"AVAudioEngineStart" code:-2 userInfo:nil];
            }
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey : exception.reason ?: @"unknown ObjC exception",
                @"ExceptionName" : exception.name ?: @"unknown",
            };
            *error = [NSError errorWithDomain:ObjCExceptionCatcherErrorDomain code:-1 userInfo:userInfo];
        }
        return NO;
    }
}

+ (BOOL)installTapOnNode:(AVAudioNode *)node
                   onBus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(AVAudioFormat * _Nullable)format
                   block:(AVAudioNodeTapBlock)block
             removeFirst:(BOOL)removeFirst
                   error:(NSError **)error {
    @try {
        if (removeFirst) {
            [node removeTapOnBus:bus];
        }
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey : exception.reason ?: @"unknown ObjC exception",
                @"ExceptionName" : exception.name ?: @"unknown",
            };
            *error = [NSError errorWithDomain:ObjCExceptionCatcherErrorDomain code:-1 userInfo:userInfo];
        }
        return NO;
    }
}

@end
