#pragma once

#import <Foundation/Foundation.h>

inline NSDictionary *SessionDictionary(id value)
{
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

inline NSArray *SessionArray(id value)
{
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

inline NSString *SessionString(id value)
{
    return [value isKindOfClass:NSString.class] ? value : nil;
}

inline NSNumber *SessionNumber(id value)
{
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}