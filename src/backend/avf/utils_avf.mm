#ifdef WITH_AVF

#include "utils_avf.hpp"
#import <Foundation/Foundation.h>

namespace bias {

    std::string nsstring_to_std(NSString *s)
    {
        if (s == nil) {
            return std::string();
        }
        const char *cstr = [s UTF8String];
        return cstr ? std::string(cstr) : std::string();
    }

    NSString *std_to_nsstring(const std::string &s)
    {
        return [NSString stringWithUTF8String:s.c_str()];
    }

}

#endif
