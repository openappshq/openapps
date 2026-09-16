#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <CoreAudio/CoreAudio.h>
#include <stdatomic.h>

// Messages to Rust (`engine.rs` applies them): kind, value, text.
//   0 key down, 1 key up (key code, logical key name); 2 forget held keys
//   100 Input Monitoring permission: 1 granted
//   101 microphone: 0 idle, 1 in use, 2 unknown, 3 detection unavailable
//   102 Mac resting (sleep, screens off, session inactive): 1 paused
//   103 default output device changed; reopen the audio output
//   104 frontmost app changed (bundle identifier in text)
//   105 secure input: 1 active
//   106 default output route: 1 built-in speakers, 0 anything else (headphones jack,
//       Bluetooth, USB, HDMI, DisplayPort, AirPlay, virtual devices, no device)
//   107 drag-to-grant helper panel: 1 shown, 0 hidden (closed by the user, or by itself once
//       the permission is granted)
typedef void (*OKCallback)(int kind, unsigned short key, const char *value);
static OKCallback callback;
static CFMachPortRef keyTap;
static CFRunLoopSourceRef keySource;
static char logicalKeys[128][40];
static NSMutableSet<NSNumber *> *processes;
static AudioObjectPropertyListenerBlock inputListener, dataSourceListener;
static AudioObjectID outputDevice = kAudioObjectUnknown;
static bool dataSourceWatched;
static int lastPermission = -1, lastSecure = -1, lastMic = -1, lastRoute = -1;
static dispatch_source_t permissionTimer;
static unsigned int suspensionReasons;
static void hideHelper(void);

char *ok_application_id(const char *path) {
    @autoreleasepool {
        NSString *identifier = [NSBundle bundleWithPath:[NSString stringWithUTF8String:path]].bundleIdentifier;
        return identifier ? strdup(identifier.UTF8String) : NULL;
    }
}
void ok_free_string(char *value) { free(value); }

typedef void (*OKVolumeCallback)(const char *preset, double volume);
@interface OKVolumeView : NSView
@property(nonatomic, copy) NSString *preset;
@property(nonatomic) OKVolumeCallback changed;
@property(nonatomic, strong) NSTextField *label;
@end
@implementation OKVolumeView
- (void)changeVolume:(NSSlider *)slider {
    self.label.stringValue = [NSString stringWithFormat:@"Volume · %.0f%%", slider.doubleValue];
    self.changed(self.preset.UTF8String, slider.doubleValue);
}
@end

void ok_tray_volume(void *status, const char *preset, double volume, OKVolumeCallback changed) {
    NSStatusItem *item = (__bridge NSStatusItem *)status;
    for (NSMenuItem *entry in item.menu.itemArray) {
        if (![entry.title hasPrefix:@"Volume ·"]) continue;
        OKVolumeView *view = [[OKVolumeView alloc] initWithFrame:NSMakeRect(0, 0, 240, 62)];
        view.preset = [NSString stringWithUTF8String:preset];
        view.changed = changed;
        view.label = [NSTextField labelWithString:entry.title];
        view.label.frame = NSMakeRect(18, 37, 208, 18);
        view.label.font = [NSFont menuFontOfSize:13];
        [view addSubview:view.label];
        NSSlider *slider = [NSSlider sliderWithValue:volume minValue:0 maxValue:100 target:view action:@selector(changeVolume:)];
        slider.frame = NSMakeRect(16, 10, 208, 22);
        slider.continuous = NO;
        slider.accessibilityLabel = @"Keyboard sound volume";
        [view addSubview:slider];
        entry.submenu = nil;
        entry.view = view;
        break;
    }
}

static void microphoneState(int state) {
    if (state != lastMic) { lastMic = state; if (callback) callback(101, state, ""); }
}

static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
}

static void sendState(int kind, int state) {
    if (callback) callback(kind, state, "");
}

static NSString *specialKey(unsigned short code) {
    switch (code) {
        case 36: case 76: return @"Enter";
        case 48: return @"Tab"; case 49: return @"Space";
        case 51: return @"Backspace"; case 53: return @"Escape";
        case 54: return @"MetaRight"; case 55: return @"MetaLeft";
        case 56: return @"ShiftLeft"; case 57: return @"CapsLock";
        case 58: return @"AltLeft"; case 59: return @"ControlLeft";
        case 60: return @"ShiftRight"; case 61: return @"AltRight";
        case 62: return @"ControlRight"; case 63: return @"Fn";
        case 96: return @"F5"; case 97: return @"F6"; case 98: return @"F7";
        case 99: return @"F3"; case 100: return @"F8"; case 101: return @"F9";
        case 103: return @"F11"; case 109: return @"F10"; case 111: return @"F12";
        case 118: return @"F4"; case 120: return @"F2"; case 122: return @"F1";
        case 105: return @"F13"; case 107: return @"F14"; case 113: return @"F15";
        case 106: return @"F16"; case 64: return @"F17"; case 79: return @"F18";
        case 80: return @"F19"; case 90: return @"F20";
        case 115: return @"Home"; case 116: return @"PageUp";
        case 117: return @"Delete"; case 119: return @"End";
        case 121: return @"PageDown"; case 123: return @"ArrowLeft";
        case 124: return @"ArrowRight"; case 125: return @"ArrowDown";
        case 126: return @"ArrowUp";
        default: return nil;
    }
}

static void updateLayout(void) {
    TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
    CFDataRef data = source ? TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) : NULL;
    const UCKeyboardLayout *layout = data ? (const UCKeyboardLayout *)CFDataGetBytePtr(data) : NULL;
    NSDictionary *punctuation = @{@"`": @"Backquote", @"-": @"Minus", @"=": @"Equal",
        @"[": @"BracketLeft", @"]": @"BracketRight", @"\\": @"Backslash", @";": @"Semicolon",
        @"'": @"Quote", @",": @"Comma", @".": @"Period", @"/": @"Slash"};
    for (unsigned short code = 0; code < 128; code++) {
        NSString *name = specialKey(code);
        if (!name && layout) {
            UInt32 dead = 0; UniChar chars[4]; UniCharCount count = 0;
            OSStatus result = UCKeyTranslate(layout, code, kUCKeyActionDown, 0,
                LMGetKbdType(), kUCKeyTranslateNoDeadKeysBit, &dead, 4, &count, chars);
            if (result == noErr && count > 0) {
                NSString *base = [[NSString stringWithCharacters:chars length:count] lowercaseString];
                if (count == 1 && chars[0] >= 'a' && chars[0] <= 'z')
                    name = [@"Key" stringByAppendingString:base.uppercaseString];
                else if (count == 1 && chars[0] >= '0' && chars[0] <= '9')
                    name = [@"Digit" stringByAppendingString:base];
                else name = punctuation[base] ?: [@"Char:" stringByAppendingString:base];
            }
        }
        strlcpy(logicalKeys[code], name.UTF8String ?: "Unknown", sizeof(logicalKeys[code]));
    }
    if (source) CFRelease(source);
}

static CGEventRef keyEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy; (void)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        sendState(2, 0);
        if (keyTap) CGEventTapEnable(keyTap, true);
        return event;
    }
    unsigned short code = (unsigned short)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (code >= 128 || !callback) return event;
    bool down = type == kCGEventKeyDown;
    if (type == kCGEventFlagsChanged) {
        if (code == 57) {
            callback(0, code, logicalKeys[code]);
            callback(1, code, logicalKeys[code]);
            return event;
        }
        down = CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, code);
    }
    if (down && CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) return event;
    callback(down ? 0 : 1, code, logicalKeys[code]);
    return event;
}

static void ensureTap(void) {
    int allowed = CGPreflightListenEventAccess();
    if (allowed != lastPermission) { lastPermission = allowed; sendState(100, allowed); }
    if (allowed) hideHelper();
    int secure = IsSecureEventInputEnabled();
    if (secure != lastSecure) { lastSecure = secure; sendState(105, secure); sendState(2, 0); }
    if (!allowed) return;
    if (keyTap && CFMachPortIsValid(keyTap)) {
        if (!CGEventTapIsEnabled(keyTap)) CGEventTapEnable(keyTap, true);
        return;
    }
    if (keySource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), keySource, kCFRunLoopCommonModes);
        CFRelease(keySource); keySource = NULL;
    }
    if (keyTap) { CFRelease(keyTap); keyTap = NULL; }
    keyTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
        CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventFlagsChanged),
        keyEvent, NULL);
    if (!keyTap) { sendState(100, 0); return; }
    keySource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, keyTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), keySource, kCFRunLoopCommonModes);
    CGEventTapEnable(keyTap, true);
}

static void readMicrophone(void) {
    int state = 0;
    AudioObjectPropertyAddress running = address(kAudioProcessPropertyIsRunningInput);
    for (NSNumber *process in processes) {
        UInt32 active = 0, size = sizeof(active);
        OSStatus result = AudioObjectGetPropertyData(process.unsignedIntValue, &running, 0, NULL, &size, &active);
        if (result != noErr) state = 2;
        else if (active) { state = 1; break; }
    }
    microphoneState(state);
}

static void refreshProcesses(void) {
    AudioObjectPropertyAddress list = address(kAudioHardwarePropertyProcessObjectList);
    UInt32 size = 0;
    if (!AudioObjectHasProperty(kAudioObjectSystemObject, &list)) {
        microphoneState(3); return;
    }
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &list, 0, NULL, &size) != noErr) {
        microphoneState(2); return;
    }
    NSMutableData *storage = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &list, 0, NULL, &size, storage.mutableBytes) != noErr) {
        microphoneState(2); return;
    }
    NSMutableSet<NSNumber *> *next = [NSMutableSet set];
    AudioObjectID *ids = storage.mutableBytes;
    AudioObjectPropertyAddress running = address(kAudioProcessPropertyIsRunningInput);
    for (UInt32 index = 0; index < size / sizeof(AudioObjectID); index++) {
        NSNumber *process = @(ids[index]);
        [next addObject:process];
        if (![processes containsObject:process])
            AudioObjectAddPropertyListenerBlock(ids[index], &running, dispatch_get_main_queue(), inputListener);
    }
    for (NSNumber *process in processes)
        if (![next containsObject:process])
            AudioObjectRemovePropertyListenerBlock(process.unsignedIntValue, &running, dispatch_get_main_queue(), inputListener);
    processes = next;
    readMicrophone();
}

static AudioObjectPropertyAddress outputAddress(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeOutput,
                                       kAudioObjectPropertyElementMain};
}

// 1 when the default output plays through the built-in speakers: the transport is built-in and
// the output data source is the internal speaker ('ispk'), or the device does not say. The
// headphones jack ('hdpn') and every other transport (Bluetooth, USB, HDMI, DisplayPort,
// AirPlay, virtual devices) are 0, as is having no output device at all.
static int outputRoute(AudioObjectID device) {
    if (device == kAudioObjectUnknown) return 0;
    UInt32 transport = 0, size = sizeof(transport);
    AudioObjectPropertyAddress transportAddress = address(kAudioDevicePropertyTransportType);
    if (AudioObjectGetPropertyData(device, &transportAddress, 0, NULL, &size, &transport) != noErr
        || transport != kAudioDeviceTransportTypeBuiltIn) return 0;
    UInt32 source = 0;
    size = sizeof(source);
    AudioObjectPropertyAddress sourceAddress = outputAddress(kAudioDevicePropertyDataSource);
    if (!AudioObjectHasProperty(device, &sourceAddress)
        || AudioObjectGetPropertyData(device, &sourceAddress, 0, NULL, &size, &source) != noErr) return 1;
    return source == 'ispk';
}

// Follows the default output device: the data-source listener moves to the new device (the
// jack on one built-in device flips the source between speakers and headphones), then the
// route is sent when it differs from the last one.
static void readOutputRoute(void) {
    AudioObjectPropertyAddress defaultOutput = address(kAudioHardwarePropertyDefaultOutputDevice);
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &defaultOutput, 0, NULL, &size, &device) != noErr)
        device = kAudioObjectUnknown;
    AudioObjectPropertyAddress source = outputAddress(kAudioDevicePropertyDataSource);
    if (device != outputDevice) {
        if (dataSourceWatched)
            AudioObjectRemovePropertyListenerBlock(outputDevice, &source, dispatch_get_main_queue(), dataSourceListener);
        outputDevice = device;
        dataSourceWatched = device != kAudioObjectUnknown && AudioObjectHasProperty(device, &source)
            && AudioObjectAddPropertyListenerBlock(device, &source, dispatch_get_main_queue(), dataSourceListener) == noErr;
    }
    int route = outputRoute(device);
    if (route != lastRoute) { lastRoute = route; sendState(106, route); }
}

void ok_request_permission(void) {
    CGRequestListenEventAccess();
    ensureTap();
    if (!CGPreflightListenEventAccess())
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
}

// The drag-to-grant helper: a small floating panel beside System Settings that offers the app
// icon to drag into the Input Monitoring list, for when OpenKlack is not listed there yet.
// A non-activating utility panel, so a drag out of it never brings OpenKlack to the front and
// System Settings stays where it is. The panel is made once and reused; hiding is `close`
// with `releasedWhenClosed` off, and every way it disappears (Close, the title bar, the
// permission arriving) passes through `windowWillClose:`, which reports kind 107.

// The icon view is the drag source. The pasteboard carries the app bundle's file URL
// (`public.file-url`), which is what Finder puts there when an app is dragged into the list.
@interface OKDragIconView : NSView <NSDraggingSource>
@property(nonatomic, strong) NSImage *icon;
@property(nonatomic, strong) NSURL *bundleURL;
@property(nonatomic) BOOL dragging;
@end
@implementation OKDragIconView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)drawRect:(NSRect)rect {
    (void)rect;
    [self.icon drawInRect:self.bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
}
- (void)mouseDragged:(NSEvent *)event {
    if (self.dragging || !self.bundleURL) return;
    self.dragging = YES;
    NSPasteboardItem *item = [NSPasteboardItem new];
    [item setString:self.bundleURL.absoluteString forType:NSPasteboardTypeFileURL];
    NSDraggingItem *drag = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
    [drag setDraggingFrame:self.bounds contents:self.icon];
    [self beginDraggingSessionWithItems:@[drag] event:event source:self];
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session;
    // Only other apps (System Settings) are a destination; the drop there is a copy of the
    // reference, never a move of the bundle.
    return context == NSDraggingContextOutsideApplication ? NSDragOperationCopy | NSDragOperationGeneric : NSDragOperationNone;
}
- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation {
    (void)session; (void)point; (void)operation;
    self.dragging = NO;
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityImageRole; }
@end

@interface OKHelperController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSTextField *status;
@property(nonatomic, strong) NSButton *reset;
@end

static NSPanel *helperPanel;
static OKHelperController *helperController;

// The screen showing System Settings (by the bounds of its windows, which need no permission),
// or the main screen.
static NSScreen *helperScreen(void) {
    NSScreen *fallback = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSArray<NSRunningApplication *> *settings =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.systempreferences"];
    if (settings.count == 0) return fallback;
    pid_t pid = settings.firstObject.processIdentifier;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return fallback;
    NSScreen *found = nil;
    for (NSDictionary *window in (__bridge NSArray *)list) {
        if ([window[(__bridge NSString *)kCGWindowOwnerPID] intValue] != pid
            || [window[(__bridge NSString *)kCGWindowLayer] intValue] != 0) continue;
        CGRect bounds;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds], &bounds)) continue;
        // Window-list bounds count from the top-left of the main display; AppKit from its bottom-left.
        CGFloat height = NSScreen.screens.firstObject.frame.size.height;
        NSPoint center = NSMakePoint(CGRectGetMidX(bounds), height - CGRectGetMidY(bounds));
        for (NSScreen *screen in NSScreen.screens)
            if (NSPointInRect(center, screen.frame)) { found = screen; break; }
        if (found) break;
    }
    CFRelease(list);
    return found ?: fallback;
}

@implementation OKHelperController
- (void)windowWillClose:(NSNotification *)note { (void)note; sendState(107, 0); }
- (void)close:(id)sender { (void)sender; hideHelper(); }
// Removes OpenKlack's own Input Monitoring entry with `tccutil reset ListenEvent <bundle id>`
// (no shell, this bundle id only), then asks again: with the entry gone, macOS shows its
// permission prompt once more and a fresh entry matching this build appears in the list. For
// a stale entry left by an earlier build or signature, which the switch in the list cannot fix.
- (void)resetPermission:(id)sender {
    (void)sender;
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    if (!identifier) return;
    self.reset.enabled = NO;
    self.status.stringValue = @"Resetting…";
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tccutil"];
    task.arguments = @[@"reset", @"ListenEvent", identifier];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *errors = [NSPipe pipe];
    task.standardError = errors;
    task.terminationHandler = ^(NSTask *finished) {
        NSString *output = [[[NSString alloc] initWithData:errors.fileHandleForReading.readDataToEndOfFile encoding:NSUTF8StringEncoding]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        int code = finished.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.reset.enabled = YES;
            if (code == 0) {
                self.status.stringValue = @"Reset. macOS asks again; allow it, then find OpenKlack in the list.";
                ok_request_permission();
            } else {
                self.status.stringValue = output.length ? output : [NSString stringWithFormat:@"tccutil failed (%d).", code];
            }
        });
    };
    NSError *error;
    if (![task launchAndReturnError:&error]) {
        self.reset.enabled = YES;
        self.status.stringValue = [NSString stringWithFormat:@"Couldn’t run tccutil: %@", error.localizedDescription];
    }
}
@end

static NSPanel *makeHelper(void) {
    helperController = [OKHelperController new];
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 300, 180)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"Allow keyboard access";
    panel.releasedWhenClosed = NO;
    panel.level = NSFloatingWindowLevel;
    panel.hidesOnDeactivate = NO;
    panel.becomesKeyOnlyIfNeeded = YES;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.delegate = helperController;
    NSView *content = panel.contentView;

    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    OKDragIconView *icon = [[OKDragIconView alloc] initWithFrame:NSMakeRect(20, 96, 64, 64)];
    icon.icon = [NSWorkspace.sharedWorkspace iconForFile:bundlePath];
    icon.bundleURL = NSBundle.mainBundle.bundleURL;
    icon.toolTip = @"Drag into the Input Monitoring list";
    icon.accessibilityLabel = @"OpenKlack app icon. Drag it into the Input Monitoring list.";
    [content addSubview:icon];

    NSTextField *instruction = [NSTextField wrappingLabelWithString:@"Drag this icon into the Input Monitoring list, then turn it on"];
    instruction.frame = NSMakeRect(100, 96, 180, 64);
    instruction.font = [NSFont systemFontOfSize:13];
    [content addSubview:instruction];

    NSTextField *status = [NSTextField wrappingLabelWithString:@""];
    status.frame = NSMakeRect(20, 52, 260, 34);
    status.font = [NSFont systemFontOfSize:11];
    status.textColor = NSColor.secondaryLabelColor;
    [content addSubview:status];
    helperController.status = status;

    NSButton *reset = [NSButton buttonWithTitle:@"Not working? Reset" target:helperController action:@selector(resetPermission:)];
    reset.frame = NSMakeRect(14, 12, 150, 32);
    reset.toolTip = @"Removes OpenKlack from the Input Monitoring list so macOS asks again";
    // Only an app bundle has an entry to reset; a bare development binary has none.
    reset.enabled = NSBundle.mainBundle.bundleIdentifier != nil;
    [content addSubview:reset];
    helperController.reset = reset;

    NSButton *close = [NSButton buttonWithTitle:@"Close" target:helperController action:@selector(close:)];
    close.frame = NSMakeRect(214, 12, 72, 32);
    [content addSubview:close];
    return panel;
}

// Shows the panel at the bottom-right of the screen with System Settings, or brings it back
// there. Ordered front without becoming key: OpenKlack stays in the background.
void ok_show_permission_helper(void) {
    if (!helperPanel) helperPanel = makeHelper();
    NSRect visible = helperScreen().visibleFrame;
    NSRect frame = helperPanel.frame;
    [helperPanel setFrameOrigin:NSMakePoint(NSMaxX(visible) - frame.size.width - 24, NSMinY(visible) + 24)];
    helperController.status.stringValue = @"";
    BOOL wasVisible = helperPanel.visible;
    [helperPanel orderFront:nil];
    if (!wasVisible) sendState(107, 1);
}

static void hideHelper(void) {
    if (helperPanel && helperPanel.visible) [helperPanel close];
}

void ok_hide_permission_helper(void) { hideHelper(); }

void ok_start(OKCallback receive) {
    callback = receive;
    updateLayout();
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspace addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *note) {
            NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
            if (callback) callback(104, 0, app.bundleIdentifier.UTF8String ?: "");
        }];
    NSArray<NSString *> *pauseNames = @[NSWorkspaceWillSleepNotification, NSWorkspaceScreensDidSleepNotification,
                                        NSWorkspaceSessionDidResignActiveNotification];
    for (NSUInteger index = 0; index < pauseNames.count; index++) {
        NSString *name = pauseNames[index];
        [workspace addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) {
                (void)note; suspensionReasons |= (1u << index); sendState(102, 1); sendState(2, 0);
            }];
    }
    NSArray<NSString *> *resumeNames = @[NSWorkspaceDidWakeNotification, NSWorkspaceScreensDidWakeNotification,
                                         NSWorkspaceSessionDidBecomeActiveNotification];
    for (NSUInteger index = 0; index < resumeNames.count; index++) {
        NSString *name = resumeNames[index];
        [workspace addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) {
                (void)note; suspensionReasons &= ~(1u << index);
                sendState(102, suspensionReasons != 0);
                if (!suspensionReasons) sendState(103, 0);
                ensureTap(); refreshProcesses(); readOutputRoute();
            }];
    }
    [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; updateLayout(); }];
    processes = [NSMutableSet set];
    inputListener = ^(UInt32 count, const AudioObjectPropertyAddress *properties) {
        (void)count; (void)properties; readMicrophone();
    };
    AudioObjectPropertyAddress list = address(kAudioHardwarePropertyProcessObjectList);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &list, dispatch_get_main_queue(),
        ^(UInt32 count, const AudioObjectPropertyAddress *properties) { (void)count; (void)properties; refreshProcesses(); });
    dataSourceListener = ^(UInt32 count, const AudioObjectPropertyAddress *properties) {
        (void)count; (void)properties; readOutputRoute();
    };
    AudioObjectPropertyAddress output = address(kAudioHardwarePropertyDefaultOutputDevice);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &output, dispatch_get_main_queue(),
        ^(UInt32 count, const AudioObjectPropertyAddress *properties) {
            (void)count; (void)properties; readOutputRoute(); sendState(103, 0);
        });
    refreshProcesses();
    readOutputRoute();
    callback(104, 0, NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier.UTF8String ?: "");
    ensureTap();
    permissionTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(permissionTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(permissionTimer, ^{ ensureTap(); });
    dispatch_resume(permissionTimer);
}

#include <IOKit/IOKitLib.h>

// The Mac's hardware UUID, copied into `buffer`. Returns 0 when it can't be read.
int ok_platform_uuid(char *buffer, int length) {
    io_service_t platform = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
    if (!platform) return 0;
    CFTypeRef uuid = IORegistryEntryCreateCFProperty(platform, CFSTR("IOPlatformUUID"), kCFAllocatorDefault, 0);
    IOObjectRelease(platform);
    if (!uuid) return 0;
    Boolean copied = CFGetTypeID(uuid) == CFStringGetTypeID() && CFStringGetCString((CFStringRef)uuid, buffer, length, kCFStringEncodingUTF8);
    CFRelease(uuid);
    return copied ? 1 : 0;
}
