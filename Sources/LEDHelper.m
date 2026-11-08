//
//  LEDHelper.m
//  TempBarApp
//
//  Privileged MagSafe LED helper (SMC key "ACLC" on Apple Silicon).
//  launchd runs this app binary as root with the --led-helper argument;
//  the menu bar app talks to it over a local unix socket.
//
//  ACLC values: 0 = macOS default, 1 = off, 3 = green, 4 = amber.
//  This helper only ever writes 0 (system default) or 1 (off).
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
#import <errno.h>
#import <time.h>
#import <string.h>

static NSString * const kVersion     = @"1.3";
static NSString * const kSocketPath  = @"/var/run/tempbar-led.sock";
static NSString * const kSupportDir  = @"/Library/Application Support/TempBarApp";
static NSString * const kConfigPath  = @"/Library/Application Support/TempBarApp/led-config.json";
static NSString * const kDaemonLabel = @"local.TempBarApp.led-helper";

static const char kLEDKey[] = "ACLC";

static const UInt8 kLEDSystemValue = 0; // hand control back to macOS
static const UInt8 kLEDOffValue    = 1; // LED dark

static NSString * const kModeSystem = @"system";
static NSString * const kModeOff    = @"off";

#pragma mark - Shared state

static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;
static NSString *gMode = nil; // kModeSystem / kModeOff

static volatile sig_atomic_t gStop = 0;
static io_connect_t gSMC = 0;
static UInt8 gLEDKeySize = 1;

// Timestamped logging — the helper log is the only forensics we have.
#define TSLOG(...) do { \
    time_t _t = time(NULL); struct tm _tm; localtime_r(&_t, &_tm); \
    char _b[24]; strftime(_b, sizeof _b, "%m-%d %H:%M:%S", &_tm); \
    fprintf(stderr, "[%s] ", _b); fprintf(stderr, __VA_ARGS__); \
} while (0)

static void stopHandler(int sig) { (void)sig; gStop = 1; }

static void lockState(void)   { pthread_mutex_lock(&gStateLock); }
static void unlockState(void) { pthread_mutex_unlock(&gStateLock); }

#pragma mark - Forensics

static void fatalSignalHandler(int sig, siginfo_t *info, void *context)
{
    (void)context;
    TSLOG("[tempbar-led] FATAL signal %d from pid %d code %d\n",
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
    TSLOG("[tempbar-led] atexit, stopFlag=%d\n", (int)gStop);
}

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
static const char kSMCReadBytes   = 5;
static const char kSMCWriteBytes  = 6;
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

#pragma mark - Config + apply

static void loadConfig(void)
{
    lockState();
    gMode = kModeSystem;
    NSDictionary *d = nil;
    NSData *configData = [NSData dataWithContentsOfFile:kConfigPath];
    if (configData) {
        d = [NSJSONSerialization JSONObjectWithData:configData options:0 error:NULL];
    }
    if ([d isKindOfClass:[NSDictionary class]]) {
        NSString *m = d[@"mode"];
        if ([m isKindOfClass:NSString.class] &&
            ([m isEqualToString:kModeSystem] || [m isEqualToString:kModeOff])) {
            gMode = m;
        }
    }
    unlockState();
}

static void saveConfigLocked(void)
{
    NSDictionary *d = @{ @"mode": gMode ?: kModeSystem };
    NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
    if (!json) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:kSupportDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    [json writeToFile:kConfigPath atomically:YES];
}

static void applyLocked(void)
{
    ledWrite([gMode isEqualToString:kModeOff] ? kLEDOffValue : kLEDSystemValue);
}

#pragma mark - Socket server

static NSDictionary *statusDictLocked(void)
{
    return @{ @"ok": @YES,
              @"version": kVersion,
              @"mode": gMode ?: kModeSystem };
}

static void writeJSONTo(int fd, NSDictionary *obj)
{
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
    if (!json) return;
    NSMutableData *out = [NSMutableData dataWithData:json];
    [out appendBytes:"\n" length:1];
    // MSG_NOSIGNAL: the menu bar app polls us and may disconnect
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
        NSString *m = req[@"mode"];
        if ([m isKindOfClass:NSString.class] &&
            ([m isEqualToString:kModeSystem] || [m isEqualToString:kModeOff])) {
            gMode = m;
            saveConfigLocked();
            applyLocked();
        }
        resp = statusDictLocked();
        unlockState();
    } else if ([cmd isEqualToString:@"probe"]) {
        // Diagnostic: write a raw ACLC value (only the documented 0/1/3/4).
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
        TSLOG("[tempbar-led] listen failed errno=%d\n", errno);
        close(fd);
        return NULL;
    }
    TSLOG("[tempbar-led] socket server ready on %s\n", path);

    while (!gStop) {
        int client = accept(fd, NULL, NULL);
        if (client < 0) {
            usleep(50 * 1000);
            continue;
        }
        // A client that never sends a newline must not wedge the single
        // accept thread forever.
        struct timeval readTimeout = { .tv_sec = 2, .tv_usec = 0 };
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, sizeof readTimeout);
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
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            mode = [NSString stringWithUTF8String:argv[++i]];
        }
    }
    if (smcOpen() != KERN_SUCCESS) return 1;
    lockState();
    gMode = [mode isEqualToString:kModeOff] ? kModeOff : kModeSystem;
    applyLocked();
    unlockState();
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
    TSLOG("[tempbar-led] daemon starting, pid=%d smcOpen=%08x\n", getpid(), openResult);
    if (openResult != KERN_SUCCESS) return 1;

    installFatalSignalLogging();
    atexit(atexitLogger);

    loadConfig();
    lockState();
    applyLocked();
    unlockState();

    pthread_t socketThread;
    pthread_create(&socketThread, NULL, serverLoop, NULL);

    // Re-apply the configured LED when the charger is (un)plugged — macOS
    // resets ACLC on power events.
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
                                                TSLOG("[tempbar-led] alive, pid=%d\n", getpid());
                                            }
                                            if (gStop) CFRunLoopStop(CFRunLoopGetMain());
                                        });
    CFRunLoopAddTimer(CFRunLoopGetMain(), stopTimer, kCFRunLoopDefaultMode);
    CFRunLoopRun();
    CFRelease(stopTimer);

    TSLOG("[tempbar-led] daemon exiting, pid=%d stopFlag=%d\n", getpid(), (int)gStop);
    IOServiceClose(gSMC);
    return 0;
}
