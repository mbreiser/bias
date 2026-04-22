#ifdef WITH_AVF
#ifndef BIAS_UTILS_AVF_HPP
#define BIAS_UTILS_AVF_HPP

#include <string>

#ifdef __OBJC__
@class NSString;
#endif

namespace bias {

#ifdef __OBJC__
    std::string nsstring_to_std(NSString *s);
    NSString *std_to_nsstring(const std::string &s);
#endif

}

#endif
#endif
