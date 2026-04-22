#ifdef WITH_AVF

#include "camera_finder_avf.hpp"
#include "utils_avf.hpp"
#import <AVFoundation/AVFoundation.h>

namespace bias {
namespace avf {

    std::vector<std::string> discoverDeviceUniqueIDs()
    {
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
