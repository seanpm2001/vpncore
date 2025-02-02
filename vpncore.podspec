Pod::Spec.new do |s|
    s.name             = 'vpncore'
    s.version          = '1.0.0'
    s.summary          = 'Core VPN components for use in ProtonVPN macOS and iOS apps'
    s.description      = 'Contains primitives, coordinators, services and extensions related to managing VPN connections.'
    s.homepage         = 'https://protonvpn.com'
    s.license          = { :type => 'GPL3', :file => 'LICENSE' }
    s.author           = { 'Proton Technologies AG' => 'contact@protonvpn.com' }
    s.source           = { :git => '', :tag => s.version.to_s }
    s.swift_version = '4.2'
    
    s.ios.deployment_target = '12.0'
    s.osx.deployment_target = '10.15'
    
    s.source_files = 'Source/*.swift', 'Source/*.sh'
    s.resource_bundle = { 'vpncore' => [
        'Source/Localization/*.lproj',
        'Source/country-names.plist',
        'Source/*.der'
        ] }

    s.ios.vendored_frameworks = 'Frameworks/*'
    s.osx.vendored_frameworks = 'Frameworks/*'
    
    s.dependency 'Alamofire', '5.3.0'
    s.dependency 'KeychainAccess', '3.2.1'
    s.dependency 'ReachabilitySwift', '5.0.0'
    s.dependency 'Sentry', '4.5.0'
    s.dependency 'TrustKit'
    # s.dependency 'TunnelKit', '~> 2.0.5'
    s.dependency 'TunnelKit'
    s.dependency 'PMNetworking'
    
end
