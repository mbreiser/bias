#ifdef WITH_AVF
#ifndef BIAS_GUID_DEVICE_AVF_HPP
#define BIAS_GUID_DEVICE_AVF_HPP

#include <string>
#include <memory>
#include "basic_types.hpp"
#include "guid_device.hpp"

namespace bias {

    class GuidDevice_avf : public GuidDevice
    {
        public:
            GuidDevice_avf();
            explicit GuidDevice_avf(std::string uniqueID);
            virtual ~GuidDevice_avf() {};
            virtual CameraLib getCameraLib();
            virtual void printValue();
            virtual std::string toString();
            std::string getValue();

        private:
            std::string value_;
            virtual bool isEqual(GuidDevice &guid);
            virtual bool lessThan(GuidDevice &guid);
            virtual bool lessThanEqual(GuidDevice &guid);
    };

    typedef std::shared_ptr<GuidDevice_avf> GuidDevicePtr_avf;
}

#endif
#endif
