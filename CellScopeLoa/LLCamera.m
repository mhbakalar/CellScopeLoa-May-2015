//
//  CaptureCamera.m
//  CellScopeLoa2
//
//  Created by Matthew Bakalar on 1/11/14.
//  Copyright (c) 2014 Matthew Bakalar. All rights reserved.
//

#import "LLCamera.h"
#import "constants.h"

@implementation LLCamera {
    AVCaptureDevice* device;
    AVCaptureDeviceInput* input;
    AVAssetWriterInputPixelBufferAdaptor* pixelBufferAdaptor;
    AVAssetWriterInputPixelBufferAdaptor* uncompressedPixelBufferAdaptor;
    AVCaptureConnection* captureConnection;
    AVCaptureVideoPreviewLayer* videoPreviewLayer;
    AVAssetWriterInput* assetWriterInput;
    AVAssetWriterInput* uncompressedAssetWriterInput;
    AVAssetWriter* assetWriter;
    AVAssetWriter* uncompressedAssetWriter;
    
    NSURL* outputURL;
    NSURL* uncompressedOutputURL;
    
    BOOL saveUncompressed;
    
    dispatch_queue_t videoQueue; // Queue for processing frames and writing video
    CMTime videoTime;
    
    NSInteger frameRate;
    float captureDuration;
}

@synthesize sampleBufferDelegate;
@synthesize recordingDelegate;
@synthesize focusDelegate;
@synthesize captureDelegate;
@synthesize frameProcessingDelegate;
@synthesize cgProcessingDelegate;
@synthesize cameraState;
@synthesize session;
@synthesize width;
@synthesize height;

- (id)init
{
    self = [super init];
    
    // Hard coded camera capture presets. Not happy about this.
    width = 480;
    height = 360;
    frameRate = 30.0;
    
    // Load any application level parameters
    saveUncompressed = [[[NSUserDefaults standardUserDefaults] objectForKey:SaveUncompressedVideoKey] boolValue];
    
    // Initialize the state of the camera
    cameraState = llCameraIdle;
    videoQueue = dispatch_queue_create("VideoQueue", DISPATCH_QUEUE_SERIAL);
    
    // Set up the AV foundation capture session
    session = [[AVCaptureSession alloc] init];
    session.sessionPreset = AVCaptureSessionPresetMedium;
    
    // Load the default capture device
    device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    
    // Set up capture input
    input = [AVCaptureDeviceInput deviceInputWithDevice:device error:nil];
    
    // Compressed assetWriterInput settings
    NSDictionary *videoCleanApertureSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                                [NSNumber numberWithInt:480], AVVideoCleanApertureWidthKey,
                                                [NSNumber numberWithInt:360], AVVideoCleanApertureHeightKey,
                                                [NSNumber numberWithInt:0], AVVideoCleanApertureHorizontalOffsetKey,
                                                [NSNumber numberWithInt:0], AVVideoCleanApertureVerticalOffsetKey,
                                                nil];
    // Codec settings
    NSDictionary *codecSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                   [NSNumber numberWithInt:20000000], AVVideoAverageBitRateKey,
                                   [NSNumber numberWithInt:5],AVVideoMaxKeyFrameIntervalKey,
                                   videoCleanApertureSettings, AVVideoCleanApertureKey,
                                   nil];

    NSDictionary *outputSettings =
    [NSDictionary dictionaryWithObjectsAndKeys:
     [NSNumber numberWithLong:width], AVVideoWidthKey,
     [NSNumber numberWithLong:height], AVVideoHeightKey,
     codecSettings, AVVideoCompressionPropertiesKey,
     AVVideoCodecH264, AVVideoCodecKey,
    nil];
    
    assetWriterInput = [AVAssetWriterInput
                             assetWriterInputWithMediaType:AVMediaTypeVideo
                             outputSettings:outputSettings];
    
    // Uncompressed assetWriterInput settings
    videoCleanApertureSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                    [NSNumber numberWithInt:480], AVVideoCleanApertureWidthKey,
                                    [NSNumber numberWithInt:360], AVVideoCleanApertureHeightKey,
                                    [NSNumber numberWithInt:0], AVVideoCleanApertureHorizontalOffsetKey,
                                    [NSNumber numberWithInt:0], AVVideoCleanApertureVerticalOffsetKey,
                                    nil];
    // Codec settings
    codecSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                       [NSNumber numberWithInt:20000000], AVVideoAverageBitRateKey,
                       [NSNumber numberWithInt:1],AVVideoMaxKeyFrameIntervalKey,
                       videoCleanApertureSettings, AVVideoCleanApertureKey,
                       nil];
    
    outputSettings =
        [NSDictionary dictionaryWithObjectsAndKeys:
         [NSNumber numberWithLong:width], AVVideoWidthKey,
         [NSNumber numberWithLong:height], AVVideoHeightKey,
         codecSettings, AVVideoCompressionPropertiesKey,
         AVVideoCodecH264, AVVideoCodecKey,
         nil];
    
    uncompressedAssetWriterInput = [AVAssetWriterInput
                        assetWriterInputWithMediaType:AVMediaTypeVideo
                        outputSettings:outputSettings];
    
    // Setup pixel buffer adaptor
    pixelBufferAdaptor =
    [[AVAssetWriterInputPixelBufferAdaptor alloc]
     initWithAssetWriterInput:assetWriterInput
     sourcePixelBufferAttributes:
     [NSDictionary dictionaryWithObjectsAndKeys:
      [NSNumber numberWithInt:kCVPixelFormatType_32BGRA],
      kCVPixelBufferPixelFormatTypeKey,
      nil]];
    
    // Setup compressed pixel buffer adaptor
    uncompressedPixelBufferAdaptor =
    [[AVAssetWriterInputPixelBufferAdaptor alloc]
     initWithAssetWriterInput:uncompressedAssetWriterInput
     sourcePixelBufferAttributes:
     [NSDictionary dictionaryWithObjectsAndKeys:
      [NSNumber numberWithInt:kCVPixelFormatType_32BGRA],
      kCVPixelBufferPixelFormatTypeKey,
      nil]];
    
    assetWriterInput.expectsMediaDataInRealTime = YES;
    uncompressedAssetWriterInput.expectsMediaDataInRealTime = YES;
    
    // Add session input and output
    [session addInput:input];

    // Setup live processing output
    AVCaptureVideoDataOutput *dataOutput = [AVCaptureVideoDataOutput new];
    dataOutput.videoSettings = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA] forKey:(NSString *)kCVPixelBufferPixelFormatTypeKey];
    [dataOutput setAlwaysDiscardsLateVideoFrames:NO];
    
    if ([self.session canAddOutput:dataOutput]) {
        [self.session addOutput:dataOutput];
    }
    
    // Setup frame buffer
    [dataOutput setSampleBufferDelegate:self queue:videoQueue];
    
    return self;
}

- (void)autoFocusStateOn
{
    cameraState = llCameraAutoFocusing;
}

- (void)autoFocusStateOff
{
    cameraState = llCameraIdle;
}

- (void)processSingleFrame
{
    cameraState = llCameraProcessingSingleFrame;
}

- (void)startSendingFrames
{
    cameraState = llCameraWritingFrames;
}

- (void)stopSendingFrames
{
    cameraState = llCameraIdle;
}

- (void)captureWithDuration:(Float32)duration URL:(NSURL*)assetURL {
    
    captureDuration = duration;
    
    // Start recording
    outputURL = assetURL;
    
    // Generate path for the uncompressed data
    if (saveUncompressed) {
        NSString* lastPath = outputURL.lastPathComponent;
        NSString* uniqueName = [lastPath substringToIndex:lastPath.length-4];
        NSString* extension = outputURL.pathExtension;
        NSString* newLastPath = [[uniqueName stringByAppendingString:@"-uncompressed."] stringByAppendingString:extension];
        uncompressedOutputURL = [outputURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Uncompressed"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:uncompressedOutputURL.path]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:uncompressedOutputURL.path withIntermediateDirectories:NO attributes:nil error:nil]; //Create folder
        }
        uncompressedOutputURL = [uncompressedOutputURL URLByAppendingPathComponent:newLastPath];
    }
    
    assetWriter = [[AVAssetWriter alloc]
                        initWithURL:outputURL
                        fileType:AVFileTypeMPEG4
                        error:nil];
    [assetWriter addInput:assetWriterInput];

    if (saveUncompressed) {
        uncompressedAssetWriter = [[AVAssetWriter alloc]
                                   initWithURL:uncompressedOutputURL
                                   fileType:AVFileTypeMPEG4
                                   error:nil];
        [uncompressedAssetWriter addInput:uncompressedAssetWriterInput];
    }
    
    [assetWriter startWriting];
    [assetWriter startSessionAtSourceTime:kCMTimeZero];
    
    if (saveUncompressed) {
        [uncompressedAssetWriter startWriting];
        [uncompressedAssetWriter startSessionAtSourceTime:kCMTimeZero];
    }
    
    videoTime = CMTimeMake(0, (int)frameRate); // Set timescale at 30 frames per second
    
    [NSTimer scheduledTimerWithTimeInterval:captureDuration/100.0
                                     target:self
                                   selector:@selector(progressClockAction:)
                                   userInfo:nil
                                    repeats:YES];
    cameraState = llCameraWritingFrames;
    NSLog(@"Start recording");
}

- (void)progressClockAction:(NSTimer *) theTimer
{
    if ((videoTime.value/(float)frameRate) >= captureDuration) {
        NSLog(@"Video Time: %d", (int)videoTime.value);
        [self recordingComplete];
        [theTimer invalidate];
        NSLog(@"Finished recording");
    }
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
       didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    // Are we recording frames right now?
    if (cameraState == llCameraWritingFrames) {
        if (assetWriterInput.readyForMoreMediaData) {
            // Has the correct number of frames been captured?
            if ((videoTime.value/(float)frameRate) >= captureDuration) {
                // Pass
            }
            else {
                if (frameProcessingDelegate != nil) {
                    // Pass the frame to the processing delegate
                    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                    [frameProcessingDelegate didReceiveFrame:imageBuffer];
                    
                    // Pass the frame to the asset writer
                    [pixelBufferAdaptor appendPixelBuffer:imageBuffer withPresentationTime:videoTime];
                    if (saveUncompressed) {
                        [uncompressedPixelBufferAdaptor appendPixelBuffer:imageBuffer withPresentationTime:videoTime];
                    }
                    
                    videoTime.value += 1;
                }
            }
        }
    }
    else if (cameraState == llCameraProcessingSingleFrame) {
        if (frameProcessingDelegate != nil) {
            CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            [frameProcessingDelegate didReceiveFrame:imageBuffer];
            NSLog(@"Process a single frame with the current processing delegate");
        }
        else {
            NSLog(@"No current processing delegate");
        }
    }
    else if (cameraState == llCameraAutoFocusing) {
        // Pass
    }
}

- (void)recordingComplete
{
    cameraState = llCameraIdle;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Signal to the processing delegate that we are done recording frames
        if (saveUncompressed) {
            [captureDelegate captureDidFinishWithURL:outputURL uncompressedURL:uncompressedOutputURL];
        }
        else {
            [captureDelegate captureDidFinishWithURL:outputURL];
        }
    });
    
    [assetWriterInput markAsFinished];
    if (saveUncompressed) {
        [uncompressedAssetWriterInput markAsFinished];
    }
    
    // Let the asset writer finish on his own
    [assetWriter finishWritingWithCompletionHandler:^(){
        // Signal the delegate that recording is complete
        [recordingDelegate captureOutput:nil didFinishRecordingToOutputFileAtURL:outputURL fromConnections:nil error:nil];
    }];
    
    if (saveUncompressed) {
        [uncompressedAssetWriter finishWritingWithCompletionHandler:^(){
            // Pass
        }];
    }
}

// Create a CGImageRef from sample buffer data
- (CGImageRef)imageFromSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferLockBaseAddress(imageBuffer,0);        // Lock the image buffer
    
    uint8_t *baseAddress = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);   // Get information of the image
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    CGContextRef newContext = CGBitmapContextCreate(baseAddress, width, height, 8, bytesPerRow, colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGImageRef newImage = CGBitmapContextCreateImage(newContext);
    CGContextRelease(newContext);
    
    CGColorSpaceRelease(colorSpace);
    CVPixelBufferUnlockBaseAddress(imageBuffer,0);
    /* CVBufferRelease(imageBuffer); */  // do not call this!
    
    return newImage;
}

- (void)startCamera
{
    [session startRunning];
    [self registerObservers];
}

- (void)stopCamera
{
    cameraState = llCameraStateStopping;
    [self clearObservers];
    // Run asynchronously so as not to block the main thread. Should fail more elegantly.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [session stopRunning];
        [session removeInput:input];
        [videoPreviewLayer removeFromSuperlayer];
        videoPreviewLayer = nil;
        session = nil;
    });
}

- (void)setManualFocusState
{
    [device lockForConfiguration:nil];
    [device setFocusMode:AVCaptureFocusModeLocked];
    [device unlockForConfiguration];
}

- (void)setContinuousAutoFocusState
{
    [device lockForConfiguration:nil];
    [device setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
    [device unlockForConfiguration];
}

- (void)setImmediateAutoFocusState
{
    [device lockForConfiguration:nil];
    [device setFocusMode:AVCaptureFocusModeAutoFocus];
    [device unlockForConfiguration];
}

- (void)setFocusLensPosition:(NSNumber*)position
{
    [device lockForConfiguration:nil];
    [device setFocusModeLockedWithLensPosition:position.floatValue completionHandler:^(CMTime syncTime) {}];
    [device unlockForConfiguration];
}

- (void)setImmediateWhiteBalanceState
{
    [device lockForConfiguration:nil];
    [device setWhiteBalanceMode:AVCaptureWhiteBalanceModeAutoWhiteBalance];
    [device unlockForConfiguration];
}

- (void)setContinuousWhiteBalanceState
{
    [device lockForConfiguration:nil];
    [device setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
    [device unlockForConfiguration];
}

- (void)setLockedWhiteBalanceState
{
    [device lockForConfiguration:nil];
    [device setWhiteBalanceMode:AVCaptureWhiteBalanceModeLocked];
    [device unlockForConfiguration];
}

- (void)setWhiteBalanceGains:(AVCaptureWhiteBalanceGains)gains
{
    [device lockForConfiguration:nil];
    [device setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:gains completionHandler:nil];
    [device unlockForConfiguration];
}

- (AVCaptureWhiteBalanceGains)getCurrentWhiteBalanceGains
{
    NSLog(@"%f", device.deviceWhiteBalanceGains.blueGain);
    NSLog(@"%f", device.deviceWhiteBalanceGains.redGain);
    NSLog(@"%f", device.deviceWhiteBalanceGains.greenGain);
    return device.deviceWhiteBalanceGains;
}

- (void)setRelativeExposure:(float)value
{
    CMTime min = device.activeFormat.minExposureDuration;
    CMTime max = device.activeFormat.maxExposureDuration;
    CMTime range = CMTimeSubtract(max, min);
    CMTime target = CMTimeAdd(CMTimeMultiplyByFloat64(range, value), min);

    [device lockForConfiguration:nil];
    [device setExposureModeCustomWithDuration:target ISO:device.ISO completionHandler:nil];
    [device unlockForConfiguration];
}

- (void)setRelativeISO:(float)iso
{
    float min = device.activeFormat.minISO;
    float max = device.activeFormat.maxISO;
    float value = (max-min)*iso + min;
    [device lockForConfiguration:nil];
    [device setExposureModeCustomWithDuration:device.exposureDuration ISO:value completionHandler:nil];
    [device unlockForConfiguration];
}

- (void)setMinimumExposure
{
    // CMTime exposure = device.activeFormat.minExposureDuration;
    CMTime exposure = CMTimeMake(1, 256);
    float iso = device.activeFormat.minISO;
    [device lockForConfiguration:nil];
    [device setExposureModeCustomWithDuration:exposure ISO:iso completionHandler:nil];
    [device unlockForConfiguration];
}

- (void)setExposure:(CMTime)exposure ISO:(float)iso
{
    [device lockForConfiguration:nil];
    [device setExposureModeCustomWithDuration:exposure ISO:iso completionHandler:nil];
    [device unlockForConfiguration];
}

- (void)setExposureMinISO:(CMTime)exposure
{
    [device lockForConfiguration:nil];
    [device setExposureModeCustomWithDuration:exposure ISO:device.activeFormat.minISO completionHandler:nil];
    [device unlockForConfiguration];
}

- (void)setAutoExposureContinuous
{
    [device lockForConfiguration:nil];
    [device setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
    [device unlockForConfiguration];
}

- (void)setColorTemperatureKelvin:(NSInteger)temperature
{
    [device lockForConfiguration:nil];
    AVCaptureWhiteBalanceTemperatureAndTintValues temperatureAndTint = {
        .temperature = temperature,
        .tint = 0,
    };
    
    AVCaptureWhiteBalanceGains gains = [device deviceWhiteBalanceGainsForTemperatureAndTintValues:temperatureAndTint];
    
    [device setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:gains completionHandler:^(CMTime syncTime) {
        // Pass
    }];
    [device unlockForConfiguration];
}

// Camera properties
- (NSNumber*)focusLensPosition
{
     return [NSNumber numberWithFloat:device.lensPosition];
}

// Autofocus observers
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if([keyPath isEqualToString:@"adjustingFocus"]){
        if (focusDelegate != nil) {
            [focusDelegate focusDidChange:[NSNumber numberWithFloat:device.lensPosition]];
        }
    }
}

// Register observer
- (void)registerObservers
{
    int flags = NSKeyValueObservingOptionNew;
    [device addObserver:self forKeyPath:@"adjustingFocus" options:flags context:nil];
}

// Unregister observer
- (void)clearObservers
{
    [device removeObserver:self forKeyPath:@"adjustingFocus"];
}

- (void)setPreviewLayer:(CALayer*)layer
{
    // Setup image preview layer with AVCaptureVideoPreviewLayer from this session
    videoPreviewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession: session];
    videoPreviewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    videoPreviewLayer.frame = layer.bounds;
    NSMutableArray *layers = [NSMutableArray arrayWithArray:layer.sublayers];
    [layers insertObject:videoPreviewLayer atIndex:0];
    layer.sublayers = [NSArray arrayWithArray:layers];
}

@end
