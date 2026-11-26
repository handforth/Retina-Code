#pragma once

#import <AppKit/AppKit.h>
#include "Lexer.hpp"

struct Theme;

struct SignatureLabel {
    NSString *text = nil;
    NSRange parameters = {};
    NSRange active = {};
    NSUInteger index = 0;
    NSUInteger count = 0;
};

@interface EditorHover : NSView
@property(nonatomic, copy) void (^pointerExited)(void);
@property(nonatomic, copy) void (^cancel)(void);
@property(nonatomic, copy) void (^viewError)(void);
@property(nonatomic, copy) void (^quickFix)(void);
- (NSSize)showDocumentation:(id)markup signature:(const SignatureLabel *)signature
                   language:(Language)language font:(NSFont *)font theme:(const Theme &)theme
                      limit:(NSSize)limit;
- (NSSize)showMessage:(NSString *)message diagnosticLabel:(NSString *)label showsQuickFix:(BOOL)quickFix
                 font:(NSFont *)font theme:(const Theme &)theme limit:(NSSize)limit;
- (BOOL)containsResponder:(NSResponder *)responder;
- (void)clear;
@end