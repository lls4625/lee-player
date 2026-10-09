#import <AVKit/AVKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Temporarily owns the single libmpv render context while system PiP is active.
/// The Flutter texture output must be released before this object is created.
API_AVAILABLE(ios(15.0))
@interface MediaKitPiPRenderer : NSObject <AVPictureInPictureSampleBufferPlaybackDelegate>

@property (nonatomic, copy, nullable) dispatch_block_t playRequested;
@property (nonatomic, copy, nullable) dispatch_block_t pauseRequested;
@property (nonatomic, copy, nullable) dispatch_block_t startTimedOut;
@property (nonatomic, copy, nullable) void (^diagnostic)(NSString *message);
/// Resolve only after the seek settles (including rejection or cancellation).
@property (nonatomic, copy, nullable) void (^seekRequested)(NSTimeInterval seconds,
                                                           void (^completion)(BOOL finished));
@property (nonatomic, copy, nullable) NSTimeInterval (^positionProvider)(void);
@property (nonatomic, copy, nullable) NSTimeInterval (^durationProvider)(void);
@property (nonatomic, copy, nullable) BOOL (^playingProvider)(void);
@property (nonatomic, copy, nullable) double (^rateProvider)(void);
@property (nonatomic, readonly, getter=isActive) BOOL active;
@property (nonatomic, readonly) AVPictureInPictureController *controller;

- (nullable instancetype)initWithPlayerHandle:(int64_t)handle
                                    sourceView:(UIView *)sourceView
                                      delegate:(id<AVPictureInPictureControllerDelegate>)delegate
                                         error:(NSError **)error;
- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END

