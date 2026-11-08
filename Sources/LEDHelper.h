#ifndef LEDHelper_h
#define LEDHelper_h

/// Entry point for the privileged MagSafe LED helper modes.
///
/// --led-helper: run as a long-lived daemon (launchd starts the app binary
///               with this argument as root).
/// --led-once  : apply a single LED state and exit
///               (--mode system|off|static [--color auto|green|amber]).
int LEDHelperMain(int argc, char *argv[]);

#endif /* LEDHelper_h */
