#!/usr/bin/env ruby
# Generate an isolated XcodeGen profile without editing the device project.
require 'yaml'
require 'pathname'
abort 'Usage: generate_simulator_project.rb FRAMEWORKS OUTPUT.yml' unless ARGV.length == 2
root = File.expand_path('..', __dir__)
base = File.join(root, 'visionos-windows-vr')
frameworks, output = ARGV.map { |value| File.expand_path(value) }
abort 'Output already exists' if File.exist?(output)
project = YAML.load_file(File.join(base, 'project.prebuilt.yml'))
project['name'] = 'VisionOSWindowsVRSimulatorExperiment'
project['packages'].each_value { |package| package['path'] = File.expand_path(package['path'], base) }
app = project['targets']['VisionOSWindowsVR']
project['targets'].delete('WindowsVRNativeBridge')
app['dependencies'].reject! { |dep| dep['target'] || dep['framework'] }
%w[WindowsVRNativeBridge WindowsRuntimePlugin].each do |name|
  path = File.join(frameworks, "#{name}.framework")
  abort "Missing #{path}" unless File.directory?(path)
  app['dependencies'] << { 'framework' => path, 'embed' => true }
end
app['sources'].each { |source| source['path'] = File.expand_path(source['path'], base) }
app['settings']['base'].merge!({
  'PRODUCT_BUNDLE_IDENTIFIER' => 'org.avpplay.simulator-experiment',
  'PRODUCT_NAME' => 'WineVision VR Simulator',
  'SUPPORTED_PLATFORMS' => 'xrsimulator', 'ARCHS' => 'arm64',
  'CODE_SIGNING_ALLOWED' => 'NO', 'CODE_SIGN_ENTITLEMENTS' => '',
  'SWIFT_OBJC_BRIDGING_HEADER' => File.join(base, 'Sources/WindowsVR-Bridging-Header.h')
})
project['targets']['SimulatorLauncherTests'] = {
  'type' => 'bundle.ui-testing', 'platform' => 'visionOS',
  'sources' => [{ 'path' => File.join(base, 'Tests/SimulatorLauncherTests.swift') }],
  'dependencies' => [{ 'target' => 'VisionOSWindowsVR' }],
  'settings' => { 'base' => {
    'PRODUCT_BUNDLE_IDENTIFIER' => 'org.avpplay.simulator-experiment.uitests',
    'TEST_TARGET_NAME' => 'VisionOSWindowsVR', 'GENERATE_INFOPLIST_FILE' => 'YES',
    'CODE_SIGNING_ALLOWED' => 'NO', 'ARCHS' => 'arm64', 'SUPPORTED_PLATFORMS' => 'xrsimulator'
  }}
}
project['schemes'] = { 'SimulatorLauncher' => {
  'build' => { 'targets' => { 'VisionOSWindowsVR' => 'all', 'SimulatorLauncherTests' => ['test'] } },
  'test' => { 'targets' => ['SimulatorLauncherTests'] }
}}
File.write(output, YAML.dump(project))
puts output
