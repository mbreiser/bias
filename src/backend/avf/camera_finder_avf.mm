#ifdef WITH_AVF

#include "camera_finder_avf.hpp"
#include "utils_avf.hpp"
#include <cstdlib>
#include <iostream>
#import <AVFoundation/AVFoundation.h>

namespace bias {
namespace avf {

    std::vector<std::string> discoverDeviceUniqueIDs()
    {
        // Emit a one-time line noting the preferred-uid override if set,
        // so users of test scripts can confirm BIAS saw their env var.
        static bool loggedPref = false;
        if (!loggedPref) {
            loggedPref = true;
            const char *pref = std::getenv("BIAS_AVF_PREFER_UID");
            if (pref && *pref) {
                std::cerr << "[bias.avf] BIAS_AVF_PREFER_UID=" << pref
                          << " — will be cam 0 (port 5010) if enumerated"
                          << std::endl;
            }
        }

        std::vector<std::string> result;
        @autoreleasepool {
            NSMutableArray<AVCaptureDeviceType> *types = [NSMutableArray array];
            [types addObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
            if (@available(macOS 14.0, *)) {
                [types addObject:AVCaptureDeviceTypeExternal];
            }
            if (@available(macOS 14.0, *)) {
                [types addObject:AVCaptureDeviceTypeContinuityCamera];
            }

            AVCaptureDeviceDiscoverySession *session =
                [AVCaptureDeviceDiscoverySession
                    discoverySessionWithDeviceTypes:types
                                          mediaType:AVMediaTypeVideo
                                           position:AVCaptureDevicePositionUnspecified];

            for (AVCaptureDevice *device in session.devices) {
                result.push_back(nsstring_to_std(device.uniqueID));
            }
        }
        return result;
    }

}
}

#endif
