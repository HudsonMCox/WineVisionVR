#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#include "WindowsVRAudioSession.h"
#include <cstdio>
#include <cstdlib>
static void require(bool value, const char *message) {
    if (!value) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
    std::printf("PASS: %s\n", message);
}
int main() { setvbuf(stdout, nullptr, _IONBF, 0); @autoreleasepool {
    require(wvr_audio_session_install_mixing_policy_v1() == 0, "install cooperative audio policy");
    require(wvr_audio_session_install_mixing_policy_v1() == 0, "installation is idempotent");
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    require([session setCategory:AVAudioSessionCategoryPlayback error:&error], "legacy playback setter succeeds");
    require([session.category isEqualToString:AVAudioSessionCategoryPlayback] &&
        (session.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers), "legacy runtime preserves helper mixing");
    require([session setCategory:AVAudioSessionCategoryAmbient error:&error], "other legacy categories still forward");
    require([session.category isEqualToString:AVAudioSessionCategoryAmbient], "other category is unchanged");
    error = nil;
    require(![session setCategory:@"WineVisionInvalidCategory" error:&error] && error != nil, "real category errors propagate");
    const auto options = AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDuckOthers;
    error = nil;
    require([session setCategory:AVAudioSessionCategoryPlayback withOptions:options error:&error], "modern explicit options succeed");
    require((session.categoryOptions & options) == options, "modern caller options remain unchanged");
    require([session setCategory:AVAudioSessionCategoryPlayback error:&error], "repeated legacy activation succeeds");
    require(session.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers, "legacy reset cannot interrupt helper audio");
    std::puts("AUDIO SESSION POLICY PROBE PASSED");
} }
