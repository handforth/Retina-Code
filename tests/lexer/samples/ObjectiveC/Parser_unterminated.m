/*
 * Parser_unterminated.m — second Objective-C sample.
 * Categories, protocols, generics, C interop, and an unterminated block comment at EOF.
 */

#import <Foundation/Foundation.h>
#include <stdlib.h>
#include "parser_internal.h"

#ifndef PARSER_MAX_DEPTH
#define PARSER_MAX_DEPTH 64
#endif

#define CHECK(cond, msg) \
    if (!(cond)) { \
        [NSException raise:NSInternalInconsistencyException \
                    format:@"%s: %@", #cond, (msg)]; \
    }

#define TOKEN_LIST(X) \
    X(Number, "number") \
    X(String, "string") \
    X(Ident,  "identifier") \
    X(Punct,  "punctuation")

typedef NS_ENUM(NSInteger, TokenKind) {
#define AS_ENUM(name, desc) TokenKind##name,
    TOKEN_LIST(AS_ENUM)
#undef AS_ENUM
    TokenKindEOF = -1,
};

typedef NS_OPTIONS(NSUInteger, ParseOptions) {
    ParseOptionsNone       = 0,
    ParseOptionsAllowNaN   = 1 << 0,
    ParseOptionsAllowHex   = 1 << 1,
    ParseOptionsStrict     = 0x1 << 2,
};

typedef struct {
    TokenKind kind;
    NSRange range;
    double number;
} Token;

@protocol ParserDelegate <NSObject>
@required
- (void)parser:(id)parser didReadToken:(Token)token;
@optional
- (BOOL)parser:(id)parser shouldContinueAfterError:(NSError *)error;
@end

NS_ASSUME_NONNULL_BEGIN

@interface Parser<__covariant ObjectType> : NSObject
@property (nonatomic, weak, nullable) id<ParserDelegate> delegate;
@property (nonatomic, readonly) NSString *source;
@property (nonatomic) ParseOptions options;
- (instancetype)initWithSource:(NSString *)source NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable NSArray<ObjectType> *)parseWithError:(NSError **)error;
@end

@interface NSString (ParserAdditions)
- (BOOL)prs_isIdentifier;
- (NSString *)prs_escaped;
@end

NS_ASSUME_NONNULL_END

@implementation NSString (ParserAdditions)

- (BOOL)prs_isIdentifier {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z_][A-Za-z0-9_]*$" options:0 error:NULL];
    });
    return [re numberOfMatchesInString:self options:0 range:NSMakeRange(0, self.length)] == 1;
}

- (NSString *)prs_escaped {
    NSMutableString *out = [NSMutableString stringWithCapacity:self.length + 2];
    [out appendString:@"\""];
    for (NSUInteger i = 0; i < self.length; i++) {
        unichar c = [self characterAtIndex:i];
        switch (c) {
            case '"':  [out appendString:@"\\\""]; break;
            case '\\': [out appendString:@"\\\\"]; break;
            case '\n': [out appendString:@"\\n"]; break;
            case '\t': [out appendString:@"\\t"]; break;
            default:
                if (c < 0x20) [out appendFormat:@"\\u%04x", c];
                else [out appendFormat:@"%C", c];
        }
    }
    [out appendString:@"\""];
    return out;
}

@end

@implementation Parser {
    NSUInteger _pos;
    NSUInteger _depth;
}

- (instancetype)initWithSource:(NSString *)source {
    if (self = [super init]) {
        _source = [source copy];
        _options = ParseOptionsAllowHex | ParseOptionsStrict;
    }
    return self;
}

- (Token)nextToken {
    Token t = { .kind = TokenKindEOF, .range = NSMakeRange(_pos, 0), .number = 0.0 };
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    while (_pos < _source.length && [ws characterIsMember:[_source characterAtIndex:_pos]]) _pos++;
    if (_pos >= _source.length) return t;
    unichar c = [_source characterAtIndex:_pos];
    if (c >= '0' && c <= '9') {
        NSScanner *sc = [NSScanner scannerWithString:[_source substringFromIndex:_pos]];
        double d = 0;
        unsigned long long hex = 0;
        if ((_options & ParseOptionsAllowHex) && [sc scanHexLongLong:&hex] && sc.scanLocation > 2) {
            d = (double)hex;
        } else {
            sc.scanLocation = 0;
            [sc scanDouble:&d];
        }
        t.kind = TokenKindNumber;
        t.number = d;
        t.range = NSMakeRange(_pos, sc.scanLocation);
        _pos += sc.scanLocation;
    } else if (c == '"' || c == '\'') {
        NSUInteger start = _pos++;
        while (_pos < _source.length && [_source characterAtIndex:_pos] != c) {
            if ([_source characterAtIndex:_pos] == '\\') _pos++;
            _pos++;
        }
        _pos++;
        t.kind = TokenKindString;
        t.range = NSMakeRange(start, _pos - start);
    } else {
        t.kind = TokenKindPunct;
        t.range = NSMakeRange(_pos++, 1);
    }
    [self.delegate parser:self didReadToken:t];
    return t;
}

- (nullable NSArray *)parseWithError:(NSError **)error {
    NSMutableArray *result = [NSMutableArray array];
    CHECK(_depth < PARSER_MAX_DEPTH, @"too deep");
    for (Token t = [self nextToken]; t.kind != TokenKindEOF; t = [self nextToken]) {
        [result addObject:[NSValue valueWithBytes:&t objCType:@encode(Token)]];
    }
    if (error) *error = nil;
    return [result copy];
}

@end

static NSString *const kSamples[] = {
    @"123 0x1F 1.5e-3",
    @"\"string with \\\"escapes\\\"\" 'single'",
    @"ident_1 + ident_2 / 3",
    @"unicode ☃ and emoji 😀",
};

double numbers[] = { 0, 1.0, .5, 5., 1e10, 1.5E-3, 0x1p4, 0x1.8p-1, 1.0f, 2.0L, 1'000'000.0 };
long long ints[] = { 0x7FFFFFFFFFFFFFFFLL, 0777, 0b1010, 42ULL, 42u, 42l, -1 };

/* This block comment is never closed.
@implementation NotReal
- (void)notCode { NSLog(@"string inside comment"); }
@end
#define NOT_A_MACRO 1
