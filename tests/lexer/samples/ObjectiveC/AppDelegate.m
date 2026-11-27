//
//  AppDelegate.m
//  Objective-C lexer stress: @-literals, blocks, preprocessor, message sends
//

#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import "AppDelegate.h"
#include <stdio.h>
@import QuartzCore;

#define APP_NAME @"Lexer Stress"
#define SQUARE(x) ((x) * (x))
#define LOG(fmt, ...) NSLog((@"%s [Line %d] " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__)
#define MULTI_LINE_MACRO(a, b) \
    do { \
        NSLog(@"a=%@", a); \
        NSLog(@"b=%@", b); \
    } while (0)
#define STRINGIFY(x) #x
#define CONCAT(a, b) a##b

#if 0
This block is disabled by the preprocessor.
It contains "unterminated strings and 'chars
and @"objc strings" and /* comments
#endif

#ifdef DEBUG
#   define DLog(...) NSLog(__VA_ARGS__)
#elif defined(BETA) && BETA > 1
#   define DLog(...) /* nothing */
#else
#   define DLog(...)
#endif

#pragma mark - Constants

static NSString * const kKey = @"key";
static NSString *const kEscapes = @"tab\t newline\n quote\" backslash\\ unicodeé";
static const char *kCString = "plain C string with \"escapes\" and \x41";
static const unichar kChar = 'a';
static const char kQuote = '\'';
static const int kMulti = 'ABCD';
NSString *const kTrailing = @"ends with backslash \\";
NSString *const kConcatenated = @"first part "
                                 @"second part "
                                 "third part without at";
// Line comment ending with a backslash continues onto the next line \
   so this line is still a comment
static int afterContinuedComment = 1;

/* Block comments do not nest in C: /* this opener is text */
static int afterBlock = 2;

@interface AppDelegate () <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, copy, nullable) NSString *title;
@property (atomic, assign, readonly) NSInteger counter;
@property (nonatomic, weak) IBOutlet NSTextField *label;
@property (nonatomic, copy) void (^completion)(BOOL success, NSError * _Nullable error);
@property (class, nonatomic, readonly) AppDelegate *shared;
@end

@implementation AppDelegate {
    NSMutableArray<NSString *> *_items;
    NSDictionary<NSString *, NSArray<NSNumber *> *> *_map;
    dispatch_queue_t _queue;
}

@synthesize counter = _counter;
@dynamic shared;

+ (AppDelegate *)shared {
    static AppDelegate *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _items = [NSMutableArray arrayWithObjects:@"a", @"b", @"c", nil];
        _map = @{ @"evens": @[@0, @2, @4], @"odds": @[@1, @3, @5] };
        _queue = dispatch_queue_create("com.example.queue", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSRect frame = NSMakeRect(0, 0, 800.0, 600.5f);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [self.window setTitle:APP_NAME];
    [self.window makeKeyAndOrderFront:nil];

    NSNumber *intNum = @42;
    NSNumber *floatNum = @3.14f;
    NSNumber *doubleNum = @2.71828;
    NSNumber *boolNum = @YES;
    NSNumber *charNum = @'x';
    NSNumber *exprNum = @(SQUARE(4) + 1);
    NSNumber *hexNum = @0xFF;
    NSNumber *unsignedNum = @42u;
    NSNumber *longNum = @42LL;
    NSArray *literalArray = @[intNum, floatNum, doubleNum, boolNum, charNum, exprNum, hexNum];
    NSDictionary *literalDict = @{ @"int": intNum, kKey: @"value", @1: @[@"nested"] };
    NSString *boxed = @(kCString);
    NSString *first = literalArray[0];
    id value = literalDict[@"int"];

    LOG(@"launched with %lu items and %@", (unsigned long)literalArray.count, value);
    MULTI_LINE_MACRO(first, boxed);

    __weak typeof(self) weakSelf = self;
    self.completion = ^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (success) {
            [strongSelf.label setStringValue:[NSString stringWithFormat:@"Done: %@ (%d%%)", strongSelf.title, 100]];
        } else {
            NSLog(@"Error: %@", error.localizedDescription);
        }
    };

    int (^adder)(int, int) = ^int(int a, int b) { return a + b; };
    __block int total = 0;
    [_items enumerateObjectsUsingBlock:^(NSString *obj, NSUInteger idx, BOOL *stop) {
        total += adder((int)idx, (int)obj.length);
        if (idx >= 2) *stop = YES;
    }];

    dispatch_async(_queue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            self.completion(total > 0, nil);
        });
    });

    @try {
        [self performSelector:@selector(missingMethod:withArg:) withObject:nil withObject:nil];
    } @catch (NSException *exception) {
        NSLog(@"Caught: %@", exception.reason);
    } @finally {
        NSLog(@"finally");
    }

    @synchronized (self) {
        _counter++;
    }

    @autoreleasepool {
        for (NSString *s in _items) {
            if ([s isEqualToString:@"b"]) continue;
            printf("%s\n", s.UTF8String);
        }
    }

    if (@available(macOS 11.0, *)) {
        NSLog(@"Big Sur or later");
    }

    Class cls = [NSString class];
    SEL sel = @selector(length);
    Protocol *proto = @protocol(NSCopying);
    const char *enc = @encode(NSRect);
    BOOL responds = [first respondsToSelector:sel] && [cls conformsToProtocol:proto];
    (void)enc; (void)responds;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        app.delegate = [AppDelegate shared];
        return NSApplicationMain(argc, argv);
    }
}
