# VLC engine for formats Apple's player can't open (MKV, AVI, WebM, WMV, FLV…).
# Downloaded from VideoLAN's official CocoaPods source at build time.
platform :ios, '17.0'
project 'VISION.xcodeproj'
inhibit_all_warnings!

target 'VISION' do
  pod 'MobileVLCKit', '~> 3.5'

  target 'VISIONTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
    end
  end
end
