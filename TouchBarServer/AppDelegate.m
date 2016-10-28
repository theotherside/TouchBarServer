//
//  AppDelegate.m
//  TouchBarServer
//
//  Created by Jesús A. Álvarez on 28/10/2016.
//  Copyright © 2016 namedfork. All rights reserved.
//

#import "AppDelegate.h"
#import <rfb/rfb.h>
@import QuartzCore;

CGDisplayStreamRef SLSDFRDisplayStreamCreate(int displayID, dispatch_queue_t queue, CGDisplayStreamFrameAvailableHandler handler);
typedef void (^DFRStatusChangeCallback)(void * arg);
void DFRSetStatus(int status);
CGSize DFRGetScreenSize();
void DFRRegisterStatusChangeCallback(DFRStatusChangeCallback callback);
void DFRFoundationPostEventWithMouseActivity(int event);

enum {
    kIOHIDDigitizerTransducerTypeStylus  = 0,
    kIOHIDDigitizerTransducerTypePuck,
    kIOHIDDigitizerTransducerTypeFinger,
    kIOHIDDigitizerTransducerTypeHand
};
typedef uint32_t IOHIDDigitizerTransducerType;

typedef double IOHIDFloat;
typedef void * IOHIDEventRef;
IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator, uint64_t timeStamp, IOHIDDigitizerTransducerType type,
                                             uint32_t index, uint32_t identity, uint32_t eventMask, uint32_t buttonMask,
                                             IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
                                             Boolean range, Boolean touch, IOOptionBits options);
IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef allocator, uint64_t timeStamp,
                                                   uint32_t index, uint32_t identity, uint32_t eventMask,
                                                   IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
                                                   Boolean range, Boolean touch, IOOptionBits options);
void IOHIDEventAppendEvent(IOHIDEventRef event, IOHIDEventRef childEvent);
CGEventRef DFRFoundationCreateCGEventWithHIDEvent(IOHIDEventRef hidEvent);
typedef struct _CGSEventRecord* CGSEventRecordRef;
CGSEventRecordRef CGEventRecordPointer(CGEventRef e);
int32_t CGSMainConnectionID();
void CGSPostEventRecord(int32_t connID, CGSEventRecordRef recordPointer, int flags1, int flags2);

@interface AppDelegate ()

- (void)rfbClient:(rfbClientPtr)client mouseEventAtPoint:(CGPoint)point buttonMask:(int)buttonMask;

@end

void PtrAddEvent(int buttonMask, int x, int y, rfbClientPtr cl) {
    [(AppDelegate*)NSApp.delegate rfbClient:cl mouseEventAtPoint:CGPointMake(x, y) buttonMask:buttonMask];
}

@implementation AppDelegate
{
    CGDisplayStreamRef touchBarStream;
    NSThread *vncThread;
    rfbScreenInfoPtr rfbScreen;
    BOOL buttonWasDown;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    touchBarStream = SLSDFRDisplayStreamCreate(0, dispatch_get_main_queue(), ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef  _Nullable frameSurface, CGDisplayStreamUpdateRef  _Nullable updateRef) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            [self startVNCServer:frameSurface];
        });
        
        // should I use a mutex or something?
        // TODO: find which area changed
        memcpy(rfbScreen->frameBuffer, IOSurfaceGetBaseAddress(frameSurface), IOSurfaceGetBytesPerRow(frameSurface) * IOSurfaceGetHeight(frameSurface));
        rfbMarkRectAsModified(rfbScreen, 0, 0, rfbScreen->width, rfbScreen->height);
    });
    
    DFRSetStatus(2);
    CGDisplayStreamStart(touchBarStream);
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}

- (void)startVNCServer:(IOSurfaceRef)buffer {
    vncThread = [[NSThread alloc] initWithTarget:self selector:@selector(runVNCServer) object:nil];
    rfbScreen = rfbGetScreen(NULL, NULL,
                             (int)IOSurfaceGetWidth(buffer),
                             (int)IOSurfaceGetHeight(buffer), 8, 3, 4);
    rfbScreen->frameBuffer = malloc( IOSurfaceGetBytesPerRow(buffer) * IOSurfaceGetHeight(buffer));
    rfbScreen->desktopName = "Touch Bar";
    rfbScreen->port = 5999;
    rfbScreen->alwaysShared = true;
    rfbScreen->cursor = NULL;
    rfbScreen->paddedWidthInBytes = (int)IOSurfaceGetBytesPerRow(buffer);
    rfbScreen->serverFormat.redShift = 16;
    rfbScreen->serverFormat.greenShift = 8;
    rfbScreen->serverFormat.blueShift = 0;
    rfbScreen->ptrAddEvent = PtrAddEvent;
    rfbInitServer(rfbScreen);
    [vncThread start];
}

- (void)runVNCServer {
    while (rfbIsActive(rfbScreen)) {
        long usec = rfbScreen->deferUpdateTime*1000;
        rfbProcessEvents(rfbScreen, usec);
    }
}

- (IOHIDEventRef)createHIDEventWithPoint:(CGPoint)point button:(BOOL)button moving:(BOOL)moving {
    uint64_t timeStamp = mach_absolute_time();
    IOHIDFloat x = point.x / rfbScreen->width;
    IOHIDEventRef digitizerEvent = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, timeStamp, kIOHIDDigitizerTransducerTypeHand, 0, 1, moving ? 3 : 35, 0, x, 0.5, 0.0, 0.0, 0.0, button, button, 0);
    IOHIDEventRef fingerEvent = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, timeStamp, 1, 1, 3, x, 0.5, 0.0, 0.0, 0.0, button, button, 0);
    IOHIDEventAppendEvent(digitizerEvent, fingerEvent);
    return digitizerEvent;
}

- (void)rfbClient:(rfbClientPtr)client mouseEventAtPoint:(CGPoint)point buttonMask:(int)buttonMask {
    BOOL buttonDown = buttonMask & 1;
    BOOL moving = buttonDown && buttonWasDown;
    if (!buttonDown && !buttonWasDown) {
        // ignore movement with mouse up
        return;
    }
    buttonWasDown = buttonDown;
    NSLog(@"mouse %s at %g", buttonDown ? "down" : "up", point.x);
    
    IOHIDEventRef *hidEvent = [self createHIDEventWithPoint:point button:buttonDown moving:moving];
    if (hidEvent) {
        CGEventRef cgEvent = DFRFoundationCreateCGEventWithHIDEvent(hidEvent);
        CFRelease(hidEvent);
        CGSEventRecordRef recordPointer = CGEventRecordPointer(cgEvent);
        CGSPostEventRecord(CGSMainConnectionID(), recordPointer, 0xf8, 0x0);
        CFRelease(cgEvent);
    }
}

@end
