import Foundation
@main struct Probe {
 static func main() {
  for name in WindowsVRTranslationEnvironment.defaults.keys { unsetenv(name) }
  setenv("FEX_MAXINST", "1024", 1)
  WindowsVRTranslationEnvironment.applyDefaults()
  assert(String(cString: getenv("FEX_MAXINST")) == "1024")
  assert(String(cString: getenv("FEX_MULTIBLOCK")) == "1")
  assert(String(cString: getenv("FEX_ENABLECODECACHINGWIP")) == "1")
  assert(String(cString: getenv("FEX_ENABLECODECACHEVALIDATION")) == "0")
  setenv("FEX_ENABLECODECACHINGWIP", "0", 1)
  WindowsVRTranslationEnvironment.applyDefaults()
  assert(String(cString: getenv("FEX_ENABLECODECACHINGWIP")) == "0")
  print("PASS: translation defaults apply before Wine, preserve explicit overrides and enable the implemented persistent cache")
 }
}
