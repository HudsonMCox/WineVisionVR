#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "../include/WindowsVRMetalDiagnostics.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <atomic>
#include <thread>
#include <vector>
int main(){ @autoreleasepool {
    wvr_metal_gpu_statistics_install();
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue=[device newCommandQueue];
    id<MTLBuffer> value=[device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    for(int n=0;n<3;n++){
        id<MTLCommandBuffer> command=[queue commandBuffer];
        command.label=n==2?@"wvr.snapshot":(n==1?@"wvr.presentation":@"guest probe");
        id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
        [blit fillBuffer:value range:NSMakeRange(0,256) value:0x2a];[blit endEncoding];
        [command commit];[command waitUntilCompleted];
        if(command.status!=MTLCommandBufferStatusCompleted || ((unsigned char*)value.contents)[0]!=0x2a)return 1;
    }
    char report[1024]={};
    if(!wvr_metal_copy_gpu_statistics(report,sizeof(report)))return 2;
    puts(report);
    if(!strstr(report,"guest submitted=1 completed=1 failed=0") || !strstr(report,"presentation submitted=1 completed=1 failed=0") || !strstr(report,"snapshot submitted=1 completed=1 failed=0"))return 3;
    double guestMean=0,guestWindow=0,guestQueue=0,presentationWindow=0,presentationQueue=0,snapshotWindow=0,snapshotQueue=0;
    const char* mean=strstr(report,"meanGPUms=");
    const char* window=strstr(report,"window guest GPUms=");
    if(!mean || !window || sscanf(mean,"meanGPUms=%lf",&guestMean)!=1 ||
       sscanf(window,"window guest GPUms=%lf queueMs=%lf presentation GPUms=%lf queueMs=%lf snapshot GPUms=%lf queueMs=%lf",
          &guestWindow,&guestQueue,&presentationWindow,&presentationQueue,&snapshotWindow,&snapshotQueue)!=6)return 4;
    if(std::abs(guestMean-guestWindow)>0.002 || guestQueue<0 || presentationQueue<0 || snapshotQueue<0)return 5;
    if(!wvr_metal_copy_gpu_statistics(report,sizeof(report)))return 6;
    window=strstr(report,"window guest GPUms=");
    if(!window || sscanf(window,"window guest GPUms=%lf queueMs=%lf presentation GPUms=%lf queueMs=%lf snapshot GPUms=%lf queueMs=%lf",
          &guestWindow,&guestQueue,&presentationWindow,&presentationQueue,&snapshotWindow,&snapshotQueue)!=6)return 7;
    if(guestWindow!=0 || guestQueue!=0 || presentationWindow!=0 || presentationQueue!=0 || snapshotWindow!=0 || snapshotQueue!=0)return 8;
    std::atomic<bool> good{true};
    std::vector<std::thread> workers;
    for (unsigned thread=0;thread<8;++thread) workers.emplace_back([&] { @autoreleasepool {
        id<MTLCommandQueue> q=[device newCommandQueue];
        id<MTLBuffer> data=[device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        for (unsigned n=0;n<32;++n) {
            id<MTLCommandBuffer> command=[q commandBuffer];
            id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
            [encoder fillBuffer:data range:NSMakeRange(0,256) value:0x2a];[encoder endEncoding];
            [command commit];[command waitUntilCompleted];
            if(command.status!=MTLCommandBufferStatusCompleted || ((unsigned char*)data.contents)[0]!=0x2a)good=false;
        }
    }});
    for(auto& worker:workers)worker.join();
    if(!good || !wvr_metal_copy_gpu_statistics(report,sizeof(report)) ||
       !strstr(report,"guest submitted=257 completed=257 failed=0") || !strstr(report,"untracked=0"))return 9;
    puts(report);
    puts("PASS: actual Metal commits/completions classified; window timings retire once; 256 concurrent slot reuses preserve GPU output");
}}
