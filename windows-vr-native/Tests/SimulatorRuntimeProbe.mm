#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "WindowsVRCompositorBridge.h"
#include "WindowsVRRuntimePlugin.h"
extern "C" void madeira_display_set_layer(CAMetalLayer *);
static CAMetalLayer *display;
static void startProbe(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    display = [CAMetalLayer layer]; display.device = device;
    display.pixelFormat = MTLPixelFormatBGRA8Unorm; display.drawableSize = CGSizeMake(32,32);
    madeira_display_set_layer(display);
    wvr_compositor_bind_metal_device_v1((__bridge void *)device);
    wvr_compositor_publish_targets_v1(32,32,MTLPixelFormatBGRA8Unorm,32,32,MTLPixelFormatBGRA8Unorm);
    NSURL *guest = [NSBundle.mainBundle URLForResource:@"guest" withExtension:@"exe" subdirectory:@"SimulatorSmoke"];
    NSDictionary *request = @{@"schemaVersion":@1,@"backend":@"windowsWineFEX",@"graphics":@"direct3D11",@"gameDirectory":guest.URLByDeletingLastPathComponent.path,@"executablePath":guest.path,@"gameID":@"simulator.smoke.x64",@"arguments":@[],@"environment":@{}};
    NSData *json = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    int status = windows_vr_launch_v1(text.UTF8String);
    NSLog(@"[WVR Simulator] launch enqueue status=%d",status);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,0);
    dispatch_source_set_event_handler(timer, ^{
        static int previous = -1;
        int state = windows_vr_status_v1();
        if(state != previous) {
            char error[4096] = {}; windows_vr_last_error_v1(error,sizeof(error));
            NSLog(@"[WVR Simulator] state=%d error=%s",state,error); previous=state;
        }
        if(state == 6 || state == 7 || status != 0) dispatch_source_cancel(timer);
    });
    dispatch_resume(timer);
}
@interface SmokeScene : UIResponder<UIWindowSceneDelegate>
@property(strong,nonatomic) UIWindow *window;
@end
@implementation SmokeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *controller = [UIViewController new];
    UILabel *label = [UILabel new]; label.text=@"Windows runtime simulator probe";
    label.textAlignment = NSTextAlignmentCenter; controller.view=label;
    self.window.rootViewController=controller; [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{startProbe();});
}
@end
@interface SmokeApp : UIResponder<UIApplicationDelegate>
@end
@implementation SmokeApp
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Smoke" sessionRole:session.role];
    config.delegateClass=SmokeScene.class; return config;
}
@end
int main(int argc,char **argv) { @autoreleasepool {
    return UIApplicationMain(argc,argv,nil,NSStringFromClass(SmokeApp.class));
} }
