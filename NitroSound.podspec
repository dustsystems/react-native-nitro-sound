require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))
folly_compiler_flags = '-DFOLLY_MOBILE=1 -DFOLLY_USE_LIBCPP=1'

Pod::Spec.new do |s|
  s.name         = "NitroSound"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "17.0" }
  s.source       = { :git => "https://github.com/hyochan/react-native-nitro-sound.git", :tag => "#{s.version}" }


  s.source_files = [
    "ios/**/*.{swift}",
    "ios/**/*.{m,mm}",
    "ios/**/*.{c,h}",
  ]

  # Public headers exposed to Swift via module
  s.public_header_files = [
    "ios/SPSCAtomic.h",
  ]

  s.exclude_files = [
    "ios/Sound-Bridging-Header.h",
  ]

  # Basic configuration - let Nitrogen handle the rest
  s.pod_target_xcconfig = {
    "SWIFT_VERSION" => "5.0",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS" => "$(inherited)",
    # Allow opting in to library evolution from environment (defaults to NO)
    "NITRO_LIBLEVOLUTION" => "NO",
    "BUILD_LIBRARY_FOR_DISTRIBUTION" => "$(NITRO_LIBLEVOLUTION)",
    "DEFINES_MODULE" => "YES",
    # Favor whole-module to avoid per-file IRGen edge-cases
    "SWIFT_COMPILATION_MODE" => "wholemodule",
    "HEADER_SEARCH_PATHS" => "$(inherited) ${PODS_ROOT}/RCT-Folly",
    "GCC_PREPROCESSOR_DEFINITIONS" => "$(inherited) FOLLY_NO_CONFIG FOLLY_MOBILE=1 FOLLY_USE_LIBCPP=1 FOLLY_CFG_NO_COROUTINES",
    "OTHER_CPLUSPLUSFLAGS" => "$(inherited) #{folly_compiler_flags}",
    "PRODUCT_MODULE_NAME" => "NitroSound",
  }

  s.dependency 'React-Core'
  s.dependency 'React-jsi'
  s.dependency 'React-callinvoker'
  s.dependency 'FluidAudio', '~> 0.6.1'
  # Note: swift-atomics replaced with C11 atomics shim (SPSCAtomic.c) for CocoaPods compatibility

  load File.join(__dir__, 'nitrogen/generated/ios/NitroSound+autolinking.rb')
  add_nitrogen_files(s)

  s.info_plist = {
    'NSMicrophoneUsageDescription' => 'This app needs access to microphone to record audio.'
  }

  install_modules_dependencies(s)
end
