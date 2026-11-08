//
//  LEDHelper.m
//  TempBarApp
//
//  Privileged MagSafe LED helper (SMC key "ACLC" on Apple Silicon).
//  launchd runs this app binary as root with the --led-helper argument;
//  the menu bar app talks to it over a local unix socket.
//
//  ACLC values: 0 = macOS default, 1 = off, 3 = green, 4 = amber.
//

#import "LEDHelper.h"

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>

#import <pthread.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <math.h>
#import <string.h>
#import <errno.h>

static NSString * const kVersion     = @"1.2";
static NSString * const kSocketPath  = @"/var/run/tempbar-led.sock";
static NSString * const kSupportDir  = @"/Library/Application Support/TempBarApp";
static NSString * const kConfigPath  = @"/Library/Application Support/TempBarApp/led-config.json";
static NSString * const kDaemonLabel = @"local.TempBarApp.led-helper";

static const char kLEDKey[] = "ACLC";

// ACLC value space (documented by the MagHue project; verified on this Mac)
static const UInt8 kLEDSystemValue = 0;
static const UInt8 kLEDOffValue    = 1;
static const UInt8 kLEDGreenValue  = 3;
static const UInt8 kLEDAmberValue  = 4;

// The LED has no brightness control, so "breathing" is software PWM:
// ACLC is toggled between off and the color value with a duty cycle that
// follows an envelope over the configured period.
static const useconds_t kTickMicros = 5000; // 5 ms -> 200 Hz tick rate
static const int        kPWMSteps   = 3;    // ~67 Hz PWM, 4 brightness steps

static NSString * const kModeSystem    = @"system";
static NSString * const kModeOff       = @"off";
static NSString * const kModeStatic    = @"static";
static NSString * const kModeBreathing = @"breathing";
static NSString * const kColorAuto     = @"auto";
static NSString * const kColorGreen    = @"green";
static NSString * const kColorAmber    = @"amber";
static NSString * const kWaveSine      = @"sine";
static NSString * const kWaveLinear    = @"linear";

#pragma mark - Shared state

static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;

static NSString *gMode   = nil;
static NSString *gColor  = nil;
static NSString *gWave   = nil;
static double     gPeriod = 4.0;

static volatile sig_atomic_t gStop = 0;
static io_connect_t gSMC = 0;
static UInt8 gLEDKeySize = 1;

static void stopHandler(int sig) { (void)sig; gStop = 1; }

// Forensics: log every catchable signal with its sender, then die.
static void fatalSignalHandler(int sig, siginfo_t *info, void *context)
{
    (void)context;
    fprintf(stderr, "[tempbar-led] FATAL signal %d from pid %d code %d\n",
            sig, info->si_pid, info->si_code);
    _exit(128 + sig);
}

static void installFatalSignalLogging(void)
{
    const int signals[] = { SIGQUIT, SIGTRAP, SIGABRT, SIGBUS, SIGFPE,
                            SIGILL, SIGSEGV, SIGSYS, SIGXCPU, SIGXFSZ };
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = fatalSignalHandler;
    sa.sa_flags = SA_SIGINFO;
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        sigaction(signals[i], &sa, NULL);
    }
}

static void atexitLogger(void)
{
    fprintf(stderr, "[tempbar-led] atexit, stopFlag=%d\n", (int)gStop);
}

static void lockState(void)   { pthread_mutex_lock(&gStateLock); }
static void unlockState(void) { pthread_mutex_unlock(&gStateLock); }

#pragma mark - SMC access

// Wire layout of the AppleSMC user-client parameter struct (kernel ABI).
typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    UInt16 release;
} SMCKeyVers;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} SMCKeyPLimit;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char   dataAttributes;
} SMCKeyInfo;

typedef struct {
    UInt32       key;
    SMCKeyVers   vers;
    SMCKeyPLimit pLimit;
    SMCKeyInfo   keyInfo;
    char         result;
    char         status;
    char         data8;
    UInt32       data32;
    UInt8        bytes[32];
} SMCParam;

// SMC user-client command bytes
static const char kSMCReadBytes  = 5;
static const char kSMCWriteBytes = 6;
static const char kSMCReadKeyInfo = 9;
// IOKit user-client selector for all SMC key operations
static const int kSMCSelector = 2;

static kern_return_t smcCall(char command, SMCParam *in, SMCParam *out)
{
    size_t inSize = sizeof(SMCParam);
    size_t outSize = sizeof(SMCParam);
    in->data8 = command;
    return IOConnectCallStructMethod(gSMC, kSMCSelector, in, inSize, out, &outSize);
}

static UInt32 packKey(const char key[4])
{
    return ((UInt32)(UInt8)key[0] << 24) |
           ((UInt32)(UInt8)key[1] << 16) |
           ((UInt32)(UInt8)key[2] << 8)  |
           ((UInt32)(UInt8)key[3]);
}

static kern_return_t smcKeyInfo(UInt32 packedKey, UInt32 *outSize)
{
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = packedKey;
    kern_return_t kr = smcCall(kSMCReadKeyInfo, &in, &out);
    if (kr == KERN_SUCCESS) *outSize = out.keyInfo.dataSize;
    return kr;
}

static kern_return_t smcReadKey(const char key[4], UInt8 outBytes[32], UInt32 *outSize)
{
    UInt32 packed = packKey(key);
    UInt32 size = 0;
    kern_return_t kr = smcKeyInfo(packed, &size);
    if (kr != KERN_SUCCESS) return kr;
    if (size == 0 || size > 32) return kIOReturnError;

    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = packed;
    in.keyInfo.dataSize = size;
    kr = smcCall(kSMCReadBytes, &in, &out);
    if (kr == KERN_SUCCESS) {
        memcpy(outBytes, out.bytes, size);
        *outSize = size;
    }
    return kr;
}

static kern_return_t smcWriteKey(const char key[4], const UInt8 *bytes, UInt32 size)
{
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = packKey(key);
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    return smcCall(kSMCWriteBytes, &in, &out);
}

static kern_return_t smcOpen(void)
{
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching("AppleSMC"));
    if (!service) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &gSMC);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) return kr;

    UInt32 size = 0;
    kr = smcKeyInfo(packKey(kLEDKey), &size);
    if (kr == KERN_SUCCESS && size > 0 && size <= 4) gLEDKeySize = (UInt8)size;
    return kr;
}

static BOOL ledWrite(UInt8 value)
{
    UInt8 buffer[32] = {0};
    buffer[0] = value;
    return smcWriteKey(kLEDKey, buffer, gLEDKeySize) == KERN_SUCCESS;
}

#pragma mark - Battery state

static BOOL batteryState(BOOL *outExternal, BOOL *outCharging)
{
    if (outExternal) *outExternal = NO;
    if (outCharging) *outCharging = NO;
    io_service_t battery = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching("AppleSmartBattery"));
    if (!battery) return NO;
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(battery, &props, kCFAllocatorDefault, 0);
    IOObjectRelease(battery);
    if (kr != KERN_SUCCESS || !props) return NO;

    NSNumber *external = (__bridge NSNumber *)CFDictionaryGetValue(props, CFSTR("ExternalConnected"));
    NSNumber *charging = (__bridge NSNumber *)CFDictionaryGetValue(props, CFSTR("IsCharging"));
    if (external && outExternal) *outExternal = external.boolValue;
    if (charging && outCharging) *outCharging = charging.boolValue;
    CFRelease(props);
    return YES;
}

#pragma mark - Config + apply

static BOOL validMode(NSString *mode)
{
    return [mode isEqualToString:kModeSystem] ||
           [mode isEqualToString:kModeOff]    ||
           [mode isEqualToString:kModeStatic] ||
           [mode isEqualToString:kModeBreathing];
}

static void loadConfig(void)
{
    lockState();
    gMode = kModeSystem;
    gColor = kColorAuto;
    gWave = kWaveSine;
    gPeriod = 4.0;
    NSDictionary *d = nil;
    NSData *configData = [NSData dataWithContentsOfFile:kConfigPath];
    if (configData) {
        d = [NSJSONSerialization JSONObjectWithData:configData options:0 error:NULL];
    }
    if ([d isKindOfClass:[NSDictionary class]]) {
        NSString *m = d[@"mode"];   if ([m isKindOfClass:NSString.class]) gMode = m;
        NSString *c = d[@"color"];  if ([c isKindOfClass:NSString.class]) gColor = c;
        NSString *w = d[@"wave"];   if ([w isKindOfClass:NSString.class]) gWave = w;
        NSNumber *p = d[@"period"]; if ([p isKindOfClass:NSNumber.class]) gPeriod = MIN(MAX(p.doubleValue, 1.0), 6.0);
        if (!validMode(gMode)) gMode = kModeSystem;
    }
    unlockState();
}

static void saveConfigLocked(void)
{
    NSDictionary *d = @{ @"mode": gMode ?: kModeSystem,
                         @"color": gColor ?: kColorAuto,
                         @"period": @(gPeriod),
                         @"wave": gWave ?: kWaveSine };
    NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
    if (!json) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:kSupportDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    [json writeToFile:kConfigPath atomically:YES];
}

// Resolved LED color for "auto": amber while charging, green when full.
// Returns nil when running on battery (LED is dark anyway).
static NSString *onColorNameLocked(void)
{
    if ([gColor isEqualToString:kColorGreen]) return kColorGreen;
    if ([gColor isEqualToString:kColorAmber]) return kColorAmber;
    BOOL external = NO, charging = NO;
    batteryState(&external, &charging);
    if (!external) return nil;
    return charging ? kColorAmber : kColorGreen;
}

static void applyLocked(void)
{
    if ([gMode isEqualToString:kModeBreathing]) return; // breathing thread owns the LED

    UInt8 value = kLEDSystemValue;
    if ([gMode isEqualToString:kModeOff]) {
        value = kLEDOffValue;
    } else if ([gMode isEqualToString:kModeStatic]) {
        NSString *color = onColorNameLocked();
        value = [color isEqualToString:kColorGreen] ? kLEDGreenValue : kLEDAmberValue;
    }
    ledWrite(value);
}

#pragma mark - Breathing thread

static void *breathingLoop(void *unused)
{
    (void)unused;
    int tick = 0;
    double t = 0.0; // seconds into the current envelope cycle
    NSString *cycleColor = nil;

    while (!gStop) {
        lockState();
        if (![gMode isEqualToString:kModeBreathing]) {
            unlockState();
            t = 0.0;
            tick = 0;
            usleep(100 * 1000); // idle while another mode owns the LED
            continue;
        }

        double period = gPeriod;
        NSString *wave = gWave;
        if (tick % 10 == 0) cycleColor = onColorNameLocked(); // track charging every ~50 ms

        double phase = t / period; // 0..1
        double envelope;
        if ([wave isEqualToString:kWaveLinear]) {
            envelope = phase < 0.5 ? phase * 2.0 : (1.0 - phase) * 2.0;
        } else {
            envelope = 0.5 - 0.5 * cos(2.0 * M_PI * phase);
        }
        int onCount = (int)lround(envelope * kPWMSteps);
        int slot = tick % kPWMSteps;
        UInt8 value = kLEDOffValue;
        if (slot < onCount && cycleColor != nil) {
            value = [cycleColor isEqualToString:kColorGreen] ? kLEDGreenValue : kLEDAmberValue;
        }
        ledWrite(value);
        unlockState();

        tick++;
        t += kTickMicros / 1000000.0;
        if (t >= period) {
            t -= period;
            tick = 0;
        }
        usleep(kTickMicros);
    }
    return NULL;
}

#pragma mark - Socket server

static NSDictionary *statusDictLocked(void)
{
    BOOL external = NO, charging = NO;
    batteryState(&external, &charging);
    return @{ @"ok": @YES,
              @"version": kVersion,
              @"mode": gMode ?: kModeSystem,
              @"color": gColor ?: kColorAuto,
              @"period": @(gPeriod),
              @"wave": gWave ?: kWaveSine,
              @"externalPower": @(external),
              @"charging": @(charging) };
}

static void writeJSONTo(int fd, NSDictionary *obj)
{
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
    if (!json) return;
    NSMutableData *out = [NSMutableData dataWithData:json];
    [out appendBytes:"\n" length:1];
    // MSG_NOSIGNAL: the menu bar app polls us every 5 s and may disconnect
    // mid-response — writing to that socket must not kill us with SIGPIPE.
    send(fd, out.bytes, out.length, MSG_NOSIGNAL);
}

static void handleRequest(int fd, NSDictionary *req)
{
    NSString *cmd = [req[@"cmd"] isKindOfClass:NSString.class] ? req[@"cmd"] : nil;
    NSDictionary *resp = nil;

    if ([cmd isEqualToString:@"ping"]) {
        resp = @{ @"ok": @YES, @"version": kVersion };
    } else if ([cmd isEqualToString:@"get"]) {
        lockState();
        resp = statusDictLocked();
        unlockState();
    } else if ([cmd isEqualToString:@"set"]) {
        lockState();
        NSString *m = req[@"mode"];   if ([m isKindOfClass:NSString.class]) gMode = m;
        NSString *c = req[@"color"];  if ([c isKindOfClass:NSString.class]) gColor = c;
        NSString *w = req[@"wave"];   if ([w isKindOfClass:NSString.class]) gWave = w;
        NSNumber *p = req[@"period"]; if ([p isKindOfClass:NSNumber.class]) gPeriod = MIN(MAX(p.doubleValue, 1.0), 6.0);
        if (![gColor isKindOfClass:NSString.class] ||
            (![gColor isEqualToString:kColorAuto] &&
             ![gColor isEqualToString:kColorGreen] &&
             ![gColor isEqualToString:kColorAmber])) gColor = kColorAuto;
        if (![gWave isEqualToString:kWaveSine] && ![gWave isEqualToString:kWaveLinear]) gWave = kWaveSine;
        if (!validMode(gMode)) gMode = kModeSystem;
        saveConfigLocked();
        applyLocked();
        resp = statusDictLocked();
        unlockState();
    } else if ([cmd isEqualToString:@"probe"]) {
        // Diagnostic: write a raw ACLC value. Meaningful in non-breathing modes
        // (breathing rewrites the key on its next tick).
        NSNumber *v = req[@"value"];
        if ([v isKindOfClass:NSNumber.class] && v.intValue >= 0 && v.intValue <= 4) {
            ledWrite((UInt8)v.intValue);
            resp = @{ @"ok": @YES, @"value": v };
        } else {
            resp = @{ @"ok": @NO };
        }
    } else {
        resp = @{ @"ok": @NO, @"error": @"unknown command" };
    }
    writeJSONTo(fd, resp);
}

static void *serverLoop(void *unused)
{
    (void)unused;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NULL;

    const char *path = kSocketPath.fileSystemRepresentation;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    unlink(path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return NULL;
    }
    chmod(path, 0666); // the menu bar app runs as the logged-in user
    if (listen(fd, 8) != 0) {
        fprintf(stderr, "[tempbar-led] listen failed errno=%d\n", errno);
        close(fd);
        return NULL;
    }
    fprintf(stderr, "[tempbar-led] socket server ready on %s\n", path);

    while (!gStop) {
        int client = accept(fd, NULL, NULL);
        if (client < 0) {
            usleep(50 * 1000);
            continue;
        }
        // read one newline-terminated JSON request
        NSMutableData *data = [NSMutableData data];
        char ch;
        while (data.length < 4096) {
            ssize_t n = read(client, &ch, 1);
            if (n <= 0 || ch == '\n') break;
            [data appendBytes:&ch length:1];
        }
        if (data.length) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) handleRequest(client, obj);
        }
        close(client);
    }
    close(fd);
    // Note: deliberately do NOT unlink(path) here — a stale socket file is
    // harmless (the next instance unlinks before bind), and removing it here
    // would break a newer instance that rebound the same path.
    return NULL;
}

#pragma mark - Power events

static void powerChanged(void *context)
{
    (void)context;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        usleep(1000 * 1000); // let the SMC settle after plug/unplug events
        lockState();
        applyLocked();
        unlockState();
    });
}

#pragma mark - Entry points

static int runOneShot(int argc, char *argv[])
{
    NSString *mode = kModeSystem;
    NSString *color = kColorAuto;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            mode = [NSString stringWithUTF8String:argv[++i]];
        } else if (strcmp(argv[i], "--color") == 0 && i + 1 < argc) {
            color = [NSString stringWithUTF8String:argv[++i]];
        }
    }
    if (smcOpen() != KERN_SUCCESS) return 1;

    UInt8 value = kLEDSystemValue;
    if ([mode isEqualToString:kModeOff]) {
        value = kLEDOffValue;
    } else if ([mode isEqualToString:kModeStatic] || [mode isEqualToString:kModeBreathing]) {
        if ([color isEqualToString:kColorGreen]) value = kLEDGreenValue;
        else if ([color isEqualToString:kColorAmber]) value = kLEDAmberValue;
        else {
            BOOL external = NO, charging = NO;
            batteryState(&external, &charging);
            value = external ? (charging ? kLEDAmberValue : kLEDGreenValue) : kLEDOffValue;
        }
    }
    ledWrite(value);
    IOServiceClose(gSMC);
    return 0;
}

int LEDHelperMain(int argc, char *argv[])
{
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--led-once") == 0) return runOneShot(argc, argv);
    }

    signal(SIGTERM, stopHandler);
    signal(SIGINT, stopHandler);
    signal(SIGHUP, SIG_IGN);
    signal(SIGPIPE, SIG_IGN); // clients may disconnect mid-conversation

    kern_return_t openResult = smcOpen();
    fprintf(stderr, "[tempbar-led] daemon starting, pid=%d smcOpen=%08x\n", getpid(), openResult);
    if (openResult != KERN_SUCCESS) return 1;

    installFatalSignalLogging();
    atexit(atexitLogger);

    loadConfig();
    lockState();
    applyLocked();
    unlockState();

    pthread_t breathThread;
    pthread_t socketThread;
    pthread_create(&breathThread, NULL, breathingLoop, NULL);
    pthread_create(&socketThread, NULL, serverLoop, NULL);

    // Re-apply the configured LED when the charger is (un)plugged — macOS
    // resets ACLC on power events, so breathing/static modes need a nudge.
    CFRunLoopSourceRef powerSource = IOPSNotificationCreateRunLoopSource(powerChanged, NULL);
    if (powerSource) {
        CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, kCFRunLoopDefaultMode);
        CFRelease(powerSource);
    }

    CFRunLoopTimerRef stopTimer =
        CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
                                        CFAbsoluteTimeGetCurrent() + 1.0, 1.0, 0, 0,
                                        ^(CFRunLoopTimerRef timer) {
                                            (void)timer;
                                            static int heartbeat = 0;
                                            if (++heartbeat % 60 == 0) {
                                                fprintf(stderr, "[tempbar-led] alive, pid=%d\n", getpid());
                                            }
                                            if (gStop) CFRunLoopStop(CFRunLoopGetMain());
                                        });
    CFRunLoopAddTimer(CFRunLoopGetMain(), stopTimer, kCFRunLoopDefaultMode);
    CFRunLoopRun();
    CFRelease(stopTimer);

    fprintf(stderr, "[tempbar-led] daemon exiting, pid=%d stopFlag=%d\n", getpid(), (int)gStop);
    IOServiceClose(gSMC);
    return 0;
}
