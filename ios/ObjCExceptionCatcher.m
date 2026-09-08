#import "ObjCExceptionCatcher.h"

NSString *const ObjCExceptionCatcherErrorDomain = @"ObjCException";

@implementation ObjCExceptionCatcher

+ (BOOL)reconnectPlayers:(NSArray<AVAudioPlayerNode *> *)players
                   engine:(AVAudioEngine *)engine
                    error:(NSError **)error {
    @try {
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

@end
