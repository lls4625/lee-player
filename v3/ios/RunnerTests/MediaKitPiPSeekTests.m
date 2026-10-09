#import <XCTest/XCTest.h>
#import "../Runner/MediaKitPiPRenderer.h"

@interface MediaKitPiPSeekTests : XCTestCase
@end

@implementation MediaKitPiPSeekTests

// Exercise the real delegate without opening libmpv or a system PiP window.
// The default NSObject initializer leaves the rendering backend unallocated.
- (MediaKitPiPRenderer *)rendererWithPosition:(NSTimeInterval (^)(void))position {
    MediaKitPiPRenderer *renderer = [MediaKitPiPRenderer new];
    AVSampleBufferDisplayLayer *layer = [AVSampleBufferDisplayLayer layer];
    CMTimebaseRef clock = NULL;
    XCTAssertEqual(CMTimebaseCreateWithSourceClock(kCFAllocatorDefault,
        CMClockGetHostTimeClock(), &clock), noErr);
    layer.controlTimebase = clock;
    CFRelease(clock);
    [renderer setValue:layer forKey:@"displayLayer"];
    renderer.positionProvider = position;
    renderer.playingProvider = ^BOOL { return NO; };
    return renderer;
}

- (double)clockPosition:(MediaKitPiPRenderer *)renderer {
    AVSampleBufferDisplayLayer *layer = [renderer valueForKey:@"displayLayer"];
    return CMTimeGetSeconds(CMTimebaseGetTime(layer.controlTimebase));
}

- (void)skip:(MediaKitPiPRenderer *)renderer seconds:(double)seconds done:(dispatch_block_t)done {
    [renderer pictureInPictureController:renderer.controller
        skipByInterval:CMTimeMakeWithSeconds(seconds, 600) completionHandler:done];
}

- (void)testSkipWaitsForResultAndSynchronizesConfirmedPositionBeforeCompletion {
    __block double position = 10;
    MediaKitPiPRenderer *renderer = [self rendererWithPosition:^{ return position; }];
    __block void (^finish)(BOOL);
    __block NSInteger completions = 0;
    renderer.seekRequested = ^(NSTimeInterval seconds, void (^completion)(BOOL)) {
        XCTAssertEqualWithAccuracy(seconds, 25, 0.001);
        finish = completion;
    };
    [self skip:renderer seconds:15 done:^{
        completions++;
        XCTAssertEqualWithAccuracy([self clockPosition:renderer], 24.75, 0.002);
    }];
    XCTAssertEqual(completions, 0);
    position = 24.75;
    finish(YES);
    XCTAssertEqual(completions, 1);
    finish(YES);
    XCTAssertEqual(completions, 1);
    [renderer stop];
}

- (void)testFailedSeekSynchronizesActualPositionAndCompletesOnce {
    MediaKitPiPRenderer *renderer = [self rendererWithPosition:^{ return 10.0; }];
    __block void (^finish)(BOOL);
    __block NSInteger completions = 0;
    renderer.seekRequested = ^(NSTimeInterval seconds, void (^completion)(BOOL)) { finish = completion; };
    [self skip:renderer seconds:15 done:^{
        completions++;
        XCTAssertEqualWithAccuracy([self clockPosition:renderer], 10, 0.002);
    }];
    XCTAssertEqual(completions, 0);
    finish(NO);
    finish(YES);
    XCTAssertEqual(completions, 1);
    [renderer stop];
}

- (void)testCompletedSeekSynchronizesPlaybackRate {
    MediaKitPiPRenderer *renderer = [self rendererWithPosition:^{ return 25.0; }];
    renderer.playingProvider = ^BOOL { return YES; };
    renderer.rateProvider = ^double { return 1.5; };
    renderer.seekRequested = ^(NSTimeInterval seconds, void (^completion)(BOOL)) { completion(YES); };
    __block NSInteger completions = 0;
    [self skip:renderer seconds:15 done:^{
        AVSampleBufferDisplayLayer *layer = [renderer valueForKey:@"displayLayer"];
        XCTAssertEqualWithAccuracy(CMTimebaseGetRate(layer.controlTimebase), 1.5, 0.001);
        XCTAssertEqualWithAccuracy([self clockPosition:renderer], 25, 0.05);
        completions++;
    }];
    XCTAssertEqual(completions, 1);
    [renderer stop];
}

- (void)testConcurrentRequestsKeepSeparateCompletionOwnership {
    MediaKitPiPRenderer *renderer = [self rendererWithPosition:^{ return 10.0; }];
    NSMutableArray *callbacks = [NSMutableArray array];
    renderer.seekRequested = ^(NSTimeInterval seconds, void (^completion)(BOOL)) {
        [callbacks addObject:[completion copy]];
    };
    __block NSInteger first = 0, second = 0;
    [self skip:renderer seconds:15 done:^{ first++; }];
    [self skip:renderer seconds:30 done:^{ second++; }];
    XCTAssertEqual(first + second, 0);
    void (^finishFirst)(BOOL) = callbacks[0];
    void (^finishSecond)(BOOL) = callbacks[1];
    finishSecond(NO); // A coalesced pending seek may be cancelled first.
    XCTAssertEqual(first, 0);
    XCTAssertEqual(second, 1);
    finishFirst(YES);
    finishSecond(YES);
    XCTAssertEqual(first, 1);
    XCTAssertEqual(second, 1);
    [renderer stop];
}

- (void)testStopCancelsEveryRequestAndIgnoresLateEngineCallbacks {
    __block double position = 10;
    MediaKitPiPRenderer *renderer = [self rendererWithPosition:^{ return position; }];
    NSMutableArray *callbacks = [NSMutableArray array];
    renderer.seekRequested = ^(NSTimeInterval seconds, void (^completion)(BOOL)) {
        [callbacks addObject:[completion copy]];
    };
    __block NSInteger completions = 0;
    [self skip:renderer seconds:15 done:^{ completions++; }];
    [self skip:renderer seconds:30 done:^{ completions++; }];
    [renderer stop];
    XCTAssertEqual(completions, 2);
    XCTAssertEqualWithAccuracy([self clockPosition:renderer], 10, 0.002);
    position = 99;
    for (void (^finish)(BOOL) in callbacks) finish(YES);
    [renderer stop];
    XCTAssertEqual(completions, 2);
    XCTAssertEqualWithAccuracy([self clockPosition:renderer], 10, 0.002);
    [self skip:renderer seconds:15 done:^{ completions++; }];
    XCTAssertEqual(completions, 3);
    XCTAssertEqual(callbacks.count, 2);
}

- (void)testDeallocationCancelsOutstandingRequest {
    __block void (^finish)(BOOL);
    __block NSInteger completions = 0;
    __weak MediaKitPiPRenderer *weakRenderer;
    @autoreleasepool {
        MediaKitPiPRenderer *renderer = [self rendererWithPosition:^{ return 10.0; }];
        weakRenderer = renderer;
        renderer.seekRequested = ^(NSTimeInterval seconds, void (^completion)(BOOL)) { finish = completion; };
        [self skip:renderer seconds:15 done:^{ completions++; }];
    }
    XCTAssertNil(weakRenderer);
    XCTAssertEqual(completions, 1);
    finish(YES);
    XCTAssertEqual(completions, 1);
}

- (void)testMissingSeekHandlerStillCompletesAndSynchronizes {
    MediaKitPiPRenderer *renderer = [self rendererWithPosition:^{ return 12.0; }];
    __block NSInteger completions = 0;
    [self skip:renderer seconds:15 done:^{ completions++; }];
    XCTAssertEqual(completions, 1);
    XCTAssertEqualWithAccuracy([self clockPosition:renderer], 12, 0.002);
    [renderer stop];
}

- (void)testInvalidIntervalRejectsWithoutSendingSeek {
    MediaKitPiPRenderer *renderer = [self rendererWithPosition:^{ return 12.0; }];
    __block NSInteger requests = 0, completions = 0;
    renderer.seekRequested = ^(NSTimeInterval seconds, void (^completion)(BOOL)) { requests++; };
    [renderer pictureInPictureController:renderer.controller skipByInterval:kCMTimeInvalid
        completionHandler:^{ completions++; }];
    XCTAssertEqual(requests, 0);
    XCTAssertEqual(completions, 1);
    [renderer stop];
}

- (void)testBackgroundEngineResultCompletesOnMainQueue {
    MediaKitPiPRenderer *renderer = [self rendererWithPosition:^{ return 12.0; }];
    XCTestExpectation *completed = [self expectationWithDescription:@"system completion"];
    __block void (^finish)(BOOL);
    renderer.seekRequested = ^(NSTimeInterval seconds, void (^completion)(BOOL)) { finish = completion; };
    [self skip:renderer seconds:15 done:^{
        XCTAssertTrue([NSThread isMainThread]);
        XCTAssertEqualWithAccuracy([self clockPosition:renderer], 12, 0.002);
        [completed fulfill];
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ finish(YES); });
    [self waitForExpectations:@[completed] timeout:2];
    [renderer stop];
}

@end
