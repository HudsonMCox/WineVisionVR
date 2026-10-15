#import <AVFAudio/AVFAudio.h>
#import <objc/runtime.h>
#include "WindowsVRAudioSession.h"

namespace {
using LegacyCategoryIMP = BOOL (*)(id, SEL, NSString *, NSError **);
using OptionsCategoryIMP = BOOL (*)(id, SEL, NSString *, AVAudioSessionCategoryOptions, NSError **);
LegacyCategoryIMP originalLegacyCategory = nullptr;
OptionsCategoryIMP originalOptionsCategory = nullptr;

BOOL CooperativeLegacyCategory(id session, SEL selector, NSString *category, NSError **error) {
    if ([category isEqualToString:AVAudioSessionCategoryPlayback]) {
        // The host owns its audio session. The preserved runtime still uses
        // the legacy API, which otherwise clears mixWithOthers set by Swift.
        // Forward the real API result/error; do not synthesize activation.
        return originalOptionsCategory(session, @selector(setCategory:withOptions:error:),
            category, AVAudioSessionCategoryOptionMixWithOthers, error);
    }
    return originalLegacyCategory(session, selector, category, error);
}
}

int32_t wvr_audio_session_install_mixing_policy_v1(void) {
    static dispatch_once_t once;
    static bool installed = false;
    dispatch_once(&once, ^{
        Method legacy = class_getInstanceMethod([AVAudioSession class], @selector(setCategory:error:));
        Method options = class_getInstanceMethod([AVAudioSession class], @selector(setCategory:withOptions:error:));
        if (!legacy || !options) return;
        originalLegacyCategory = reinterpret_cast<LegacyCategoryIMP>(method_getImplementation(legacy));
        originalOptionsCategory = reinterpret_cast<OptionsCategoryIMP>(method_getImplementation(options));
        method_setImplementation(legacy, reinterpret_cast<IMP>(CooperativeLegacyCategory));
        installed = true;
    });
    return installed ? 0 : -1;
}
