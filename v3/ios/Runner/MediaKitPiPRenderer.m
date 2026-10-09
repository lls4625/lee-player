#import "MediaKitPiPRenderer.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <media_kit_video/render.h>

static NSString *const LeeMediaKitPiPErrorDomain = @"lei.player.media-kit-pip";

@interface MediaKitPiPRenderer ()
@property (nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic) mpv_render_context *renderContext;
@property (nonatomic, strong) dispatch_queue_t renderQueue;
@property (nonatomic) BOOL stopping;
@property (nonatomic) BOOL wantsStart;
@property (nonatomic) BOOL startIssued;
@property (nonatomic) BOOL renderPending;
@property (nonatomic) BOOL renderRequested;
@property (nonatomic) BOOL enqueuePending;
@property (nonatomic, strong) NSTimer *startupTimer;
@property (nonatomic) NSInteger startupStage;
@property (nonatomic) CFTimeInterval stageStarted;
@property (nonatomic) NSUInteger submittedFrames;
@property (atomic) NSUInteger updateCount;
@property (atomic) NSUInteger renderCount;
@property (atomic) int lastRenderError;
@property (nonatomic) CFTimeInterval lastSubmission;
@property (nonatomic) BOOL playbackWasPlaying;
// Accessed on the main queue. Remove before calling out so late/duplicate
// engine callbacks and stop/dealloc cannot complete a system request twice.
@property (nonatomic, strong) NSMutableDictionary<NSUUID *, dispatch_block_t> *pendingSeeks;
@property (nonatomic, readwrite) AVPictureInPictureController *controller;
- (void)scheduleRender;
- (void)renderFrame;
- (void)startIfPossible;
- (void)finishSeek:(NSUUID *)requestID success:(BOOL)success;
- (void)synchronizePlaybackTimebase;
@end

@implementation MediaKitPiPRenderer

static void LeeMediaKitPiPUpdate(void *context) {
    MediaKitPiPRenderer *renderer = (__bridge MediaKitPiPRenderer *)context;
    [renderer scheduleRender];
}

- (nullable instancetype)initWithPlayerHandle:(int64_t)handle
                                    sourceView:(UIView *)sourceView
                                      delegate:(id<AVPictureInPictureControllerDelegate>)delegate
                                         error:(NSError **)error {
    if (![AVPictureInPictureController isPictureInPictureSupported]) {
        if (error) *error = [NSError errorWithDomain:LeeMediaKitPiPErrorDomain code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Picture in Picture is not supported"}];
        return nil;
    }
    if ((self = [super init])) {
        _sourceView = sourceView;
        _renderQueue = dispatch_queue_create("lei.player.media-kit-pip-render", DISPATCH_QUEUE_SERIAL);
        _displayLayer = [AVSampleBufferDisplayLayer layer];
        _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        _displayLayer.opaque = YES;
        _displayLayer.backgroundColor = UIColor.blackColor.CGColor;
        _displayLayer.frame = sourceView.bounds;
        [sourceView.layer insertSublayer:_displayLayer atIndex:0];

        const char *api = MPV_RENDER_API_TYPE_SW;
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, (void *)api},
            {MPV_RENDER_PARAM_INVALID, NULL},
        };
        int status = mpv_render_context_create(&_renderContext,
            (mpv_handle *)(uintptr_t)handle, params);
        if (status < 0 || !_renderContext) {
            [_displayLayer removeFromSuperlayer];
            if (error) *error = [NSError errorWithDomain:LeeMediaKitPiPErrorDomain code:2
                userInfo:@{NSLocalizedDescriptionKey: @"Unable to take over compatibility-engine video output"}];
            return nil;
        }
        mpv_render_context_set_update_callback(_renderContext, LeeMediaKitPiPUpdate,
                                                (__bridge void *)self);
        AVPictureInPictureControllerContentSource *content =
            [[AVPictureInPictureControllerContentSource alloc]
                initWithSampleBufferDisplayLayer:_displayLayer playbackDelegate:self];
        _controller = [[AVPictureInPictureController alloc] initWithContentSource:content];
        _controller.delegate = delegate;
        _controller.canStartPictureInPictureAutomaticallyFromInline = NO;
    }
    return self;
}

- (BOOL)isActive { return self.controller.isPictureInPictureActive; }

- (void)start {
    self.wantsStart = YES;
    CMTimebaseRef timebase = NULL;
    OSStatus timebaseStatus = CMTimebaseCreateWithSourceClock(kCFAllocatorDefault,
        CMClockGetHostTimeClock(), &timebase);
    if (timebaseStatus != noErr || !timebase) {
        if (self.diagnostic) self.diagnostic(@"pip media timebase creation failed");
        if (self.startTimedOut) self.startTimedOut();
        return;
    }
    CMTimebaseSetTime(timebase, CMTimeMakeWithSeconds(self.positionProvider ? self.positionProvider() : 0, 600));
    self.displayLayer.controlTimebase = timebase;
    CFRelease(timebase);
    self.stageStarted = CACurrentMediaTime();
    self.lastSubmission = self.stageStarted;
    self.startupStage = 0;
    [self scheduleRender];
    __weak typeof(self) weakSelf = self;
    self.startupTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        MediaKitPiPRenderer *renderer = weakSelf;
        if (!renderer || renderer.stopping) { [timer invalidate]; return; }
        BOOL playing = renderer.playingProvider ? renderer.playingProvider() : NO;
        double position = renderer.positionProvider ? renderer.positionProvider() : 0;
        CMTimebaseRef clock = renderer.displayLayer.controlTimebase;
        double drift = position - CMTimeGetSeconds(CMTimebaseGetTime(clock));
        if (isfinite(drift) && fabs(drift) > 0.5) {
            [renderer.displayLayer flush];
            CMTimebaseSetTime(clock, CMTimeMakeWithSeconds(position, 600));
        }
        CMTimebaseSetRate(clock, playing ? (renderer.rateProvider ? renderer.rateProvider() : 1) : 0);
        if (renderer.playbackWasPlaying != playing) {
            renderer.playbackWasPlaying = playing;
            renderer.lastSubmission = CACurrentMediaTime();
            [renderer.controller invalidatePlaybackState];
        }
        if (renderer.controller.isPictureInPictureActive) {
            if (renderer.startupStage != 3) {
                renderer.startupStage = 3;
                if (renderer.diagnostic) renderer.diagnostic(@"pip active; media timeline synchronized");
            }
            if (renderer.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed ||
                (playing && CACurrentMediaTime() - renderer.lastSubmission > 12)) {
                if (renderer.diagnostic) renderer.diagnostic([NSString stringWithFormat:
                    @"pip active frame delivery failed: %@", renderer.displayLayer.error]);
                [timer invalidate];
                if (renderer.startTimedOut) renderer.startTimedOut();
            }
            return;
        }
        [renderer startIfPossible];
        if (CACurrentMediaTime() - renderer.stageStarted > (renderer.startupStage == 0 ? 12 : 8)) {
            [timer invalidate];
            if (renderer.diagnostic) renderer.diagnostic([NSString stringWithFormat:
                @"pip timeout stage=%ld submitted=%lu possible=%d issued=%d layer=%ld error=%@",
                (long)renderer.startupStage, (unsigned long)renderer.submittedFrames,
                renderer.controller.isPictureInPicturePossible, renderer.startIssued,
                (long)renderer.displayLayer.status, renderer.displayLayer.error]);
            if (renderer.diagnostic) renderer.diagnostic([NSString stringWithFormat:
                @"pip updates=%lu rendered=%lu renderError=%d", (unsigned long)renderer.updateCount,
                (unsigned long)renderer.renderCount, renderer.lastRenderError]);
            if (renderer.startTimedOut) renderer.startTimedOut();
        }
    }];
}

- (void)startIfPossible {
    if (!self.stopping && self.submittedFrames > 0 && self.wantsStart && !self.startIssued &&
        self.controller.isPictureInPicturePossible &&
        !self.controller.isPictureInPictureActive) {
        self.startIssued = YES;
        self.startupStage = 2;
        self.stageStarted = CACurrentMediaTime();
        if (self.diagnostic) self.diagnostic(@"pip possible; start issued");
        [self.controller startPictureInPicture];
    }
}

- (void)scheduleRender {
    if (self.stopping || !self.renderContext) return;
    @synchronized (self) {
        self.renderRequested = YES;
        if (self.renderPending) return;
        self.renderPending = YES;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.renderQueue, ^{
        while (weakSelf) {
            @synchronized (weakSelf) {
                if (weakSelf.stopping || !weakSelf.renderContext) {
                    weakSelf.renderPending = NO;
                    return;
                }
                weakSelf.renderRequested = NO;
            }
            @autoreleasepool { [weakSelf renderFrame]; }
            @synchronized (weakSelf) {
                if (!weakSelf.renderRequested) {
                    weakSelf.renderPending = NO;
                    return;
                }
            }
        }
    });
}

- (void)renderFrame {
    if (self.stopping || !self.renderContext) return;
    uint64_t flags = mpv_render_context_update(self.renderContext);
    self.updateCount++;
    if (!(flags & MPV_RENDER_UPDATE_FRAME)) return;

    const int width = 640;
    const int height = 360;
    NSDictionary *attributes = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn created = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
        kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixelBuffer);
    if (created != kCVReturnSuccess || !pixelBuffer) return;

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    int size[] = {width, height};
    size_t stride = CVPixelBufferGetBytesPerRow(pixelBuffer);
    const char *format = "bgr0";
    void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_SW_SIZE, size},
        {MPV_RENDER_PARAM_SW_FORMAT, (void *)format},
        {MPV_RENDER_PARAM_SW_STRIDE, &stride},
        {MPV_RENDER_PARAM_SW_POINTER, base},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    int renderStatus = mpv_render_context_render(self.renderContext, params);
    self.lastRenderError = renderStatus;
    if (renderStatus >= 0) self.renderCount++;
    if (renderStatus >= 0) {
        // "bgr0" is the software renderer's guaranteed 4-byte BGR format.
        // Its fourth byte is unspecified (commonly zero), while a BGRA pixel
        // buffer may treat that byte as alpha. Make every rendered pixel opaque.
        uint8_t *bytes = (uint8_t *)base;
        for (int y = 0; y < height; y++) {
            uint8_t *row = bytes + (size_t)y * stride;
            for (int x = 0; x < width; x++) row[(size_t)x * 4 + 3] = 0xFF;
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    if (renderStatus < 0) {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    CMVideoFormatDescriptionRef description = NULL;
    CMSampleBufferRef sample = NULL;
    OSStatus descriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, pixelBuffer, &description);
    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    OSStatus sampleStatus = descriptionStatus == noErr
        ? CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer,
            description, &timing, &sample)
        : descriptionStatus;
    if (sampleStatus == noErr && sample) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
        if (attachments && CFArrayGetCount(attachments) > 0) {
            CFMutableDictionaryRef dictionary = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(dictionary, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
        BOOL shouldEnqueue = NO;
        @synchronized (self) {
            if (!self.enqueuePending) {
                self.enqueuePending = YES;
                shouldEnqueue = YES;
            }
        }
        if (shouldEnqueue) CFRetain(sample);
        if (shouldEnqueue) dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.stopping) {
                if (self.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
                    [self.displayLayer flush];
                }
                if (self.displayLayer.readyForMoreMediaData) {
                    // Samples and the delegate's 0...duration range must use the same media clock.
                    CMSampleTimingInfo mediaTiming = {
                        .duration = kCMTimeInvalid,
                        .presentationTimeStamp = CMTimebaseGetTime(self.displayLayer.controlTimebase),
                        .decodeTimeStamp = kCMTimeInvalid,
                    };
                    CMSampleBufferRef timedSample = NULL;
                    OSStatus result = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault,
                        sample, 1, &mediaTiming, &timedSample);
                    if (result != noErr || !timedSample) {
                        if (self.diagnostic) self.diagnostic(@"pip sample retiming failed");
                        CFRelease(sample);
                        @synchronized (self) { self.enqueuePending = NO; }
                        return;
                    }
                    [self.displayLayer enqueueSampleBuffer:timedSample];
                    CFRelease(timedSample);
                    self.lastSubmission = CACurrentMediaTime();
                    self.submittedFrames++;
                    if (self.startupStage == 0) {
                        self.startupStage = 1;
                        self.stageStarted = CACurrentMediaTime();
                        if (self.diagnostic) self.diagnostic(@"pip first sample submitted");
                    }
                }
                [self startIfPossible];
            }
            CFRelease(sample);
            @synchronized (self) { self.enqueuePending = NO; }
        });
    }
    if (sample) CFRelease(sample);
    if (description) CFRelease(description);
    CVPixelBufferRelease(pixelBuffer);
}

- (void)stop {
    if (self.stopping) return;
    self.stopping = YES;
    [self.startupTimer invalidate];
    self.startupTimer = nil;
    for (NSUUID *requestID in self.pendingSeeks.allKeys) {
        [self finishSeek:requestID success:NO];
    }
    self.seekRequested = nil;
    [self.controller stopPictureInPicture];
    if (self.renderContext) {
        mpv_render_context_set_update_callback(self.renderContext, NULL, NULL);
        dispatch_sync(self.renderQueue, ^{});
        mpv_render_context_free(self.renderContext);
        self.renderContext = NULL;
    }
    [self.displayLayer flushAndRemoveImage];
    [self.displayLayer removeFromSuperlayer];
}

- (void)dealloc { [self stop]; }

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
                        setPlaying:(BOOL)playing {
    if (self.stopping) return;
    if (playing) { if (self.playRequested) self.playRequested(); }
    else { if (self.pauseRequested) self.pauseRequested(); }
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:
    (AVPictureInPictureController *)pictureInPictureController {
    NSTimeInterval duration = self.durationProvider ? self.durationProvider() : 0;
    return CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(MAX(0, duration), 600));
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:
    (AVPictureInPictureController *)pictureInPictureController {
    return !(self.playingProvider ? self.playingProvider() : NO);
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
       didTransitionToRenderSize:(CMVideoDimensions)newRenderSize { }

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
                    skipByInterval:(CMTime)skipInterval
                 completionHandler:(void (^)(void))completionHandler {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pictureInPictureController:pictureInPictureController
                skipByInterval:skipInterval completionHandler:completionHandler];
        });
        return;
    }
    if (self.stopping) { completionHandler(); return; }
    NSUUID *requestID = [NSUUID UUID];
    if (!self.pendingSeeks) self.pendingSeeks = [NSMutableDictionary dictionary];
    self.pendingSeeks[requestID] = [completionHandler copy];
    NSTimeInterval position = self.positionProvider ? self.positionProvider() : 0;
    NSTimeInterval target = position + CMTimeGetSeconds(skipInterval);
    if (!self.seekRequested || !isfinite(target)) {
        [self finishSeek:requestID success:NO];
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.seekRequested(MAX(0, target), ^(BOOL finished) {
        // PlaybackService normally resolves on main. Keep the delegate safe if
        // a transport resolves from another queue, including after teardown.
        if ([NSThread isMainThread]) {
            [weakSelf finishSeek:requestID success:finished];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf finishSeek:requestID success:finished];
            });
        }
    });
}

- (void)synchronizePlaybackTimebase {
    CMTimebaseRef clock = self.displayLayer.controlTimebase;
    if (clock) {
        NSTimeInterval position = self.positionProvider ? self.positionProvider() : 0;
        if (isfinite(position)) {
            [self.displayLayer flush];
            CMTimebaseSetTime(clock, CMTimeMakeWithSeconds(MAX(0, position), 600));
        }
        BOOL playing = !self.stopping && (self.playingProvider ? self.playingProvider() : NO);
        double rate = self.rateProvider ? self.rateProvider() : 1;
        CMTimebaseSetRate(clock, playing && isfinite(rate) ? rate : 0);
    }
    [self.controller invalidatePlaybackState];
}

- (void)finishSeek:(NSUUID *)requestID success:(BOOL)success {
    dispatch_block_t completion = self.pendingSeeks[requestID];
    if (!completion) return;
    [self.pendingSeeks removeObjectForKey:requestID];
    // Use the confirmed engine position, even on failure/cancellation. Never
    // acknowledge the requested target before the engine has actually settled.
    [self synchronizePlaybackTimebase];
    if (!success && self.diagnostic) self.diagnostic(@"pip skip failed or cancelled");
    completion();
}

- (BOOL)pictureInPictureControllerShouldProhibitBackgroundAudioPlayback:
    (AVPictureInPictureController *)pictureInPictureController { return NO; }

@end
