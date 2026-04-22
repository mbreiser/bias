cmake_minimum_required(VERSION 3.16)

project(bias_backend_avf)

enable_language(OBJCXX)

set(
    bias_backend_avf_SOURCE
    utils_avf.mm
    guid_device_avf.mm
    camera_device_avf.mm
    camera_finder_avf.mm
    )

add_library(bias_backend_avf ${bias_backend_avf_SOURCE})

set_source_files_properties(
    ${bias_backend_avf_SOURCE}
    PROPERTIES
    COMPILE_FLAGS "-fobjc-arc"
    )

target_link_libraries(
    bias_backend_avf
    ${bias_ext_link_LIBS}
    bias_backend_base
    "-framework Foundation"
    "-framework AVFoundation"
    "-framework CoreMedia"
    "-framework CoreVideo"
    "-framework CoreFoundation"
    )
