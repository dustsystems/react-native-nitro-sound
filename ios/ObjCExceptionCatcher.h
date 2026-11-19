#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Reconnects `players` to `engine`'s main mixer at the engine's current hardware format and
/// restarts it — entirely in Objective-C, inside `@try/@catch`.
///
/// This exists because Objective-C exceptions (raised by `disconnectNodeOutput:`/`connect:...`/
/// `prepare` on a bad graph) are NOT safely catchable by an `@try/@catch` that wraps a Swift
/// closure — confirmed empirically on DUS-1714 (three separate live reproductions, both with
/// and without an intermediate Swift wrapper function, all trapped `EXC_BREAKPOINT` instead of
/// being caught: identical to the production crash this exists to fix, Sentry `DUST-APP-QV`).
/// The only reliable shape is the whole risky sequence running as pure Objective-C with zero
/// Swift frames between the `@try` and the calls that can raise — which is what this does.
@interface ObjCExceptionCatcher : NSObject

/// Stops `engine` first if it's already running (safe to call either way — repairs a graph left
/// dangling by a prior failed attempt just as well as a genuinely stopped engine), then
/// reconnects and restarts. Returns `YES` on success. On `NO`, `*error` is populated: either the
/// `NSError` from `startAndReturnError:` (domain from AVFoundation), or one built from a caught
/// `NSException` (domain `ObjCException`, `userInfo` carrying the exception's name and reason).
+ (BOOL)reconnectPlayers:(NSArray<AVAudioPlayerNode *> *)players
                   engine:(AVAudioEngine *)engine
                    error:(NSError **)error NS_SWIFT_NAME(reconnectPlayers(_:engine:));

/// Installs a tap on `node`'s `bus`, optionally removing an existing tap first —
/// entirely in Objective-C, inside `@try/@catch`.
///
/// Same reason as `reconnectPlayers:engine:`: `removeTapOnBus:` / `installTapOnBus:…`
/// raise `NSException` on a bad graph (tap already installed, invalid/zero format,
/// node not in the engine), and Swift `do/catch` cannot see those. The tap `block`
/// may be a Swift closure; the exception is at install time, not inside the block.
/// Do not wrap a Swift closure in a `tryBlock` — DUS-1714 proved that still traps
/// (`EXC_BREAKPOINT`). Returns `YES` on success. On `NO`, `*error` is an
/// `NSError` built from the caught `NSException` (domain `ObjCException`).
+ (BOOL)installTapOnNode:(AVAudioNode *)node
                   onBus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(nullable AVAudioFormat *)format
                   block:(AVAudioNodeTapBlock)block
             removeFirst:(BOOL)removeFirst
                   error:(NSError **)error
    NS_SWIFT_NAME(installTap(on:bus:bufferSize:format:block:removeFirst:));

/// Starts `node` (`play`) — entirely in Objective-C, inside `@try/@catch`.
///
/// Same reason as the two methods above: `play` raises `NSException` when the node's engine
/// is not running or the node is not connected, and an `isRunning` check before it cannot
/// close that window, because the engine can be stopped on another queue between the check
/// and the call (DUS-3322: a phone call during an alarm). Returns `YES` on success. On `NO`,
/// `*error` is an `NSError` built from the caught `NSException` (domain `ObjCException`).
+ (BOOL)playNode:(AVAudioPlayerNode *)node
           error:(NSError **)error NS_SWIFT_NAME(play(_:));

/// Nap mode (experiment), additive. Attaches `player` to `engine` and connects it to the
/// main mixer (`format` nil = the node's own output format, as the other players use),
/// inside `@try/@catch`. The engine may be running. On `NO` the node is detached again
/// when it had been attached.
+ (BOOL)attachPlayer:(AVAudioPlayerNode *)player
            toEngine:(AVAudioEngine *)engine
              format:(nullable AVAudioFormat *)format
               error:(NSError **)error NS_SWIFT_NAME(attachPlayer(_:to:format:));

/// Nap mode (experiment), additive. Queues `file` three times on `player`, the last with
/// `refill` as its completion handler (the looping pattern the ambient layer uses), inside
/// `@try/@catch`. Does not stop or start the node.
+ (BOOL)queueLoopFile:(AVAudioFile *)file
             onPlayer:(AVAudioPlayerNode *)player
               refill:(AVAudioNodeCompletionHandler)refill
                error:(NSError **)error NS_SWIFT_NAME(queueLoopFile(_:on:refill:));

/// Nap mode (experiment), additive. Stops `player`, queues `file` as `queueLoopFile` does
/// and plays it, inside `@try/@catch`. `play` is only called while the node's engine is
/// running; check `player.isPlaying` afterwards.
+ (BOOL)restartLoopOnPlayer:(AVAudioPlayerNode *)player
                       file:(AVAudioFile *)file
                     refill:(AVAudioNodeCompletionHandler)refill
                      error:(NSError **)error NS_SWIFT_NAME(restartLoop(on:file:refill:));

/// Nap mode (experiment), additive. Queues `silence` on `player` with no completion handler
/// and plays it, inside `@try/@catch`. `play` is only called while the node's engine is
/// running. Used to run a player at volume 0 for a moment before its first loop.
+ (BOOL)primePlayer:(AVAudioPlayerNode *)player
            silence:(AVAudioPCMBuffer *)silence
              error:(NSError **)error NS_SWIFT_NAME(primePlayer(_:silence:));

/// Nap mode (experiment), additive. Stops `player` if it is still attached to an engine,
/// inside `@try/@catch`.
+ (BOOL)stopPlayer:(AVAudioPlayerNode *)player
             error:(NSError **)error NS_SWIFT_NAME(stopPlayer(_:));

@end

NS_ASSUME_NONNULL_END
