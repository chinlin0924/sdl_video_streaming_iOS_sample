//
//  ProxyManager.m
//  SDLStreamingVideoExample
//
//  Created by Nicole on 8/4/17.
//  Copyright © 2017 Livio. All rights reserved.
//

#import "SmartDeviceLink.h"
#import "ProxyManager.h"
#import "VideoManager.h"
#import "TouchManagerHandler.h"

NSString *const SDLAppName = @"SDLVideo";
NSString *const SDLAppId = @"2776";
NSString *const SDLIPAddress = @"192.168.1.236";
UInt16 const SDLPort = (UInt16)2776;

BOOL const ShouldRestartOnDisconnect = NO;

typedef NS_ENUM(NSUInteger, SDLHMIFirstState) {
    SDLHMIFirstStateNone,
    SDLHMIFirstStateNonNone,
    SDLHMIFirstStateFull
};

typedef NS_ENUM(NSUInteger, SDLHMIInitialShowState) {
    SDLHMIInitialShowStateNone,
    SDLHMIInitialShowStateDataAvailable,
    SDLHMIInitialShowStateShown
};


NS_ASSUME_NONNULL_BEGIN

@interface ProxyManager () <SDLManagerDelegate, SDLTouchManagerDelegate>

// Describes the first time the HMI state goes non-none and full.
@property (assign, nonatomic) SDLHMIFirstState firstTimeState;
@property (assign, nonatomic) SDLHMIInitialShowState initialShowState;
@property (nonatomic, nullable) id videoPeriodicTimer;

// Screen touches
@property (nonatomic, strong) SDLTouchManager *touchManager;

@end


@implementation ProxyManager

#pragma mark - getters
- (SDLTouchManager *)touchManager {
    return self.sdlManager.streamManager.touchManager;
}

#pragma mark - Initialization

+ (instancetype)sharedManager {
    static ProxyManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[ProxyManager alloc] init];
    });

    return sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _state = ProxyStateStopped;
    _firstTimeState = SDLHMIFirstStateNone;
    _initialShowState = SDLHMIInitialShowStateNone;

    return self;
}

- (void)startIAP {
    [self sdlex_updateProxyState:ProxyStateSearchingForConnection];

    // Return if there is already an instance of sdlManager
    if (self.sdlManager) { return; }

    // To stream video, the app type must be "Navigation". Video will not work with other app types.
    SDLLifecycleConfiguration *lifecycleConfig = [self.class sdlex_setLifecycleConfigurationPropertiesOnConfiguration:[SDLLifecycleConfiguration defaultConfigurationWithAppName:SDLAppName appId:SDLAppId]];

    // Navigation apps must have a SDLStreamingMediaConfiguration
    SDLConfiguration *config = [SDLConfiguration configurationWithLifecycle:lifecycleConfig lockScreen:[SDLLockScreenConfiguration enabledConfiguration] logging:[[self class] sdlex_logConfiguration] streamingMedia:[SDLStreamingMediaConfiguration insecureConfiguration]];

    self.sdlManager = [[SDLManager alloc] initWithConfiguration:config delegate:self];

    [self startManager];
}

- (void)startTCP {
    [self sdlex_updateProxyState:ProxyStateSearchingForConnection];
    // Return if there is already an instance of sdlManager
    if (self.sdlManager) { return; }

    // To stream video, the app type must be "Navigation". Video will not work with other app types.
    SDLLifecycleConfiguration *lifecycleConfig = [self.class sdlex_setLifecycleConfigurationPropertiesOnConfiguration:[SDLLifecycleConfiguration debugConfigurationWithAppName:SDLAppName appId:SDLAppId ipAddress:SDLIPAddress port:SDLPort]];

    // Navigation apps must have a SDLStreamingMediaConfiguration
    SDLConfiguration *config = [SDLConfiguration configurationWithLifecycle:lifecycleConfig lockScreen:[SDLLockScreenConfiguration enabledConfiguration] logging:[[self class] sdlex_logConfiguration] streamingMedia:[SDLStreamingMediaConfiguration insecureConfiguration]];

    self.sdlManager = [[SDLManager alloc] initWithConfiguration:config delegate:self];

    [self startManager];
}

- (void)startManager {
    __weak typeof (self) weakSelf = self;
    [self.sdlManager startWithReadyHandler:^(BOOL success, NSError * _Nullable error) {
        if (!success) {
            SDLLogE(@"SDL errored starting up: %@", error);
            [weakSelf sdlex_updateProxyState:ProxyStateStopped];
            return;
        }

        SDLLogD(@"SDL Connected");
        [weakSelf sdlex_updateProxyState:ProxyStateConnected];
    }];
}

- (void)reset {
    [self sdlex_updateProxyState:ProxyStateStopped];
    [self.sdlManager stop];
    // Remove reference
    self.sdlManager = nil;
}

#pragma mark - Helpers

+ (SDLLifecycleConfiguration *)sdlex_setLifecycleConfigurationPropertiesOnConfiguration:(SDLLifecycleConfiguration *)config {

    config.shortAppName = @"Video";
    config.voiceRecognitionCommandNames = @[@"S D L Video"];
    config.ttsName = [SDLTTSChunk textChunksFromString:config.shortAppName];
    config.appType = SDLAppHMITypeNavigation;

    return config;
}

+ (SDLLogConfiguration *)sdlex_logConfiguration {
    SDLLogConfiguration *logConfig = [SDLLogConfiguration debugConfiguration];
    SDLLogFileModule *sdlExampleModule = [SDLLogFileModule moduleWithName:@"SDLVideo" files:[NSSet setWithArray:@[@"ProxyManager"]]];
    logConfig.modules = [logConfig.modules setByAddingObject:sdlExampleModule];
    logConfig.targets = [logConfig.targets setByAddingObject:[SDLLogTargetFile logger]];

    return logConfig;
}

/**
 KVO for the proxy state. The proxy can change between being connected, stopped, and searching for connection.

 @param newState The new proxy state
 */
- (void)sdlex_updateProxyState:(ProxyState)newState {
    if (self.state != newState) {
        [self willChangeValueForKey:@"state"];
        _state = newState;
        [self didChangeValueForKey:@"state"];
    }
}

#pragma mark - SDLManagerDelegate

- (void)managerDidDisconnect {
    // Reset our state
    self.firstTimeState = SDLHMIFirstStateNone;
    self.initialShowState = SDLHMIInitialShowStateNone;
    self.videoPeriodicTimer = nil;
    [VideoManager.sharedManager reset];
    [self sdlex_updateProxyState:ProxyStateStopped];
    if (ShouldRestartOnDisconnect) {
        [self startManager];
    }
}

- (void)hmiLevel:(SDLHMILevel)oldLevel didChangeToLevel:(SDLHMILevel)newLevel {
    if (![newLevel isEqualToEnum:SDLHMILevelNone] && (self.firstTimeState == SDLHMIFirstStateNone)) {
        // This is our first time in a non-NONE state
        self.firstTimeState = SDLHMIFirstStateNonNone;

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sdlex_stopStreamingVideo) name:UIApplicationWillResignActiveNotification object:nil];
    }

    if ([newLevel isEqualToEnum:SDLHMILevelFull] && (self.firstTimeState != SDLHMIFirstStateFull)) {
        // This is our first time in a FULL state
        self.firstTimeState = SDLHMIFirstStateFull;
    }

    if ([newLevel isEqualToEnum:SDLHMILevelFull] || [newLevel isEqualToEnum:SDLHMILevelLimited]) {
        [self sdlex_setupStreamingVideo];
    } else {
        [self sdlex_stopStreamingVideo];
    }
}

#pragma mark - Streaming Video

/**
 *  Sets up the buffer to send the video to SDL Core.
 */
- (void)sdlex_setupStreamingVideo {
    if (self.videoPeriodicTimer != nil) { return; }

    if (!self.sdlManager.streamManager.isVideoStreamingSupported) {
        // Check if Core can support video
        self.videoPeriodicTimer = nil;
        return;
    }

    if (VideoManager.sharedManager.player == nil) {
        // Video player is not yet setup
        [self registerForNotificationWhenVideoStartsPlaying];
    } else if (VideoManager.sharedManager.player.rate == 1.0) {
        // Video is already playing, setup the buffer to send video to SDL Core
        [self sdlex_startStreamingVideo];
    } else {
        // Video player is setup but nothing is playing yet
        [self registerForNotificationWhenVideoStartsPlaying];
    }
}

/**
 *  Registers for a callback when the video player starts playing
 */
- (void)registerForNotificationWhenVideoStartsPlaying {
    // Video is not yet playing. Register to get a notification when video starts playing
    VideoManager.sharedManager.videoStreamingStartedHandler = ^{
        [self sdlex_startStreamingVideo];
    };
}

/**
 *  Registers for a callback from the video player on each new video frame. When the notification is received, an image is created from the current video frame and sent to the SDL Core.
 */
- (void)sdlex_startStreamingVideo {
    if (self.videoPeriodicTimer != nil) { return; }

    // Screen is touch enabled
    self.sdlManager.streamManager.touchManager.touchEventDelegate = self;
//    self.sdlManager.streamManager.touchManager.touchEventHandler = ^(SDLTouch * _Nonnull touch, SDLTouchType  _Nonnull type) {
//        NSLog(@"touched 😮");
//    };

    // self.touchHandler.delegate = self;

    __weak typeof(self) weakSelf = self;
    self.videoPeriodicTimer = [VideoManager.sharedManager.player addPeriodicTimeObserverForInterval:CMTimeMake(1, 30) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            // Due to an iOS limitation of VideoToolbox's encoder and openGL, video streaming can not happen in the background
            SDLLogW(@"Video streaming can not occur in background");
            self.videoPeriodicTimer = nil;
            return;
        }
        // Grab an image of the current video frame and send it to SDL Core
        CVPixelBufferRef buffer = [VideoManager.sharedManager getPixelBuffer];
        [weakSelf sdlex_sendVideo:buffer];
        [VideoManager.sharedManager releasePixelBuffer:buffer];
    }];
}

/**
 *  Stops registering for a callback from the video player on each new video frame.
 */
- (void)sdlex_stopStreamingVideo {
    if (self.videoPeriodicTimer == nil) { return; }
    [VideoManager.sharedManager.player removeTimeObserver:self.videoPeriodicTimer];
    self.videoPeriodicTimer = nil;
}

/**
 *  Send the video to SDL Core
 *
 *  @param imageBuffer  The image(s) to send to SDL Core
 */
- (void)sdlex_sendVideo:(CVPixelBufferRef)imageBuffer {
    if (imageBuffer == nil || [self.sdlManager.hmiLevel isEqualToEnum:SDLHMILevelNone] || [self.sdlManager.hmiLevel isEqualToEnum:SDLHMILevelBackground]) {
        // Video can only be sent when HMI level is full or limited
        return;
    }

    Boolean success = [self.sdlManager.streamManager sendVideoData:imageBuffer];
    NSLog(@"Video was sent %@", success ? @"successfully" : @"unsuccessfully");
}

#pragma mark - Delegates

#pragma mark SDLTouchManagerDelegate
/**
 *  Single tap was received.
 */
- (void)touchManager:(SDLTouchManager *)manager didReceiveSingleTapAtPoint:(CGPoint)point {
    NSLog(@"Single Tap: x: %f, y: %f", point.x, point.y);
}

/**
 *  Double tap was received.
 */
- (void)touchManager:(SDLTouchManager *)manager didReceiveDoubleTapAtPoint:(CGPoint)point {
    NSLog(@"Double Tap: x: %f, y: %f", point.x, point.y);
}

#pragma mark Panning

/**
 *  Panning did start.
 */
- (void)touchManager:(SDLTouchManager *)manager panningDidStartAtPoint:(CGPoint)point {
    NSLog(@"Panning started: x: %f, y: %f", point.x, point.y);
}

/**
 *  Panning did move.
 */
- (void)touchManager:(SDLTouchManager *)manager didReceivePanningFromPoint:(CGPoint)fromPoint toPoint:(CGPoint)toPoint {
    NSLog(@"Panning From x: %f, y: %f, To x: %f, y: %f", fromPoint.x, fromPoint.y, toPoint.x, toPoint.y);
}

/**
 *  Panning did end.
 */
- (void)touchManager:(SDLTouchManager *)manager panningDidEndAtPoint:(CGPoint)point {
    NSLog(@"Panning ended: x: %f, y: %f", point.x, point.y);
}

#pragma mark Pinch

/**
 *  Pinch did start.
 */
- (void)touchManager:(SDLTouchManager *)manager pinchDidStartAtCenterPoint:(CGPoint)point {
    NSLog(@"Pinch started: center x: %f, center y: %f", point.x, point.y);
}

/**
 *  Pinch did move.
 */
- (void)touchManager:(SDLTouchManager *)manager didReceivePinchAtCenterPoint:(CGPoint)point withScale:(CGFloat)scale {
    NSLog(@"Pinch moved: center x: %f, center y: %f, with scale: %f", point.x, point.y, scale);
}

/**
 *  Pinch did end.
 */
- (void)touchManager:(SDLTouchManager *)manager pinchDidEndAtCenterPoint:(CGPoint)point {
    NSLog(@"Pinch ended: center x: %f, center y: %f", point.x, point.y);
}

#pragma mark SDLTouchManagerHandler
- (void)touchManagerHandlerShouldZoomIn:(TouchManagerHandler *)handler {
    NSLog(@"Got something...");
}

@end

NS_ASSUME_NONNULL_END
