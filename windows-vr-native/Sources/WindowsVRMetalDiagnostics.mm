// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import "WindowsVRMetalDiagnostics.h"
#include <mutex>
#include <chrono>
#include <array>
#include <cstdio>
#ifndef WVR_SOURCE_AIR_WRITER
#define WVR_SOURCE_AIR_WRITER 0
#endif
#if WVR_SOURCE_AIR_WRITER
#include "../shader-compiler/WindowsVRAIRWriter.h"
#endif

// Preserve the +1 ownership of Metal's new... methods across the C IMP boundary.
typedef id (*LibraryIMP)(id, SEL, dispatch_data_t, NSError **) NS_RETURNS_RETAINED;
typedef id (*RenderIMP)(id, SEL, MTLRenderPipelineDescriptor *, NSError **) NS_RETURNS_RETAINED;
typedef id (*RenderOptionsIMP)(id, SEL, MTLRenderPipelineDescriptor *, MTLPipelineOption, MTLRenderPipelineReflection **, NSError **) NS_RETURNS_RETAINED;
typedef id (*ComputeIMP)(id, SEL, MTLComputePipelineDescriptor *, MTLPipelineOption, MTLComputePipelineReflection **, NSError **) NS_RETURNS_RETAINED;
static LibraryIMP originalLibrary;
static RenderIMP originalRender;
static RenderOptionsIMP originalRenderOptions;
static ComputeIMP originalCompute;
static NSLock *captureLock;
static NSURL *captureDirectory;
static NSMutableSet<NSString *> *capturedHashes;
static NSUInteger failureCount;
static bool captureEnabled;
static std::mutex failureMutex;
static NSString *compilerFailure;
static NSMutableDictionary<NSString *, NSData *> *shaderInputs;
static NSUInteger shaderInputBytes;
static bool failureExported;
static NSMutableSet<NSString *> *exportedPipelineKeys;
static NSUInteger exportedPipelineBytes;
static NSArray<NSDictionary *> *offlinePipelines;

static void RememberShaderInput(dispatch_data_t data, id<MTLLibrary> library) {
    if (!library || !data) return;
    const void *bytes = nullptr;
    size_t size = 0;
    dispatch_data_t mapped = dispatch_data_create_map(data, &bytes, &size);
    if (!mapped || !bytes || !size || size > 8 * 1024 * 1024) return;
    std::lock_guard<std::mutex> lock(failureMutex);
    if (shaderInputBytes + size > 16 * 1024 * 1024 || failureExported) return;
    NSData *copy = [NSData dataWithBytes:bytes length:size];
    if (!shaderInputs) shaderInputs = [NSMutableDictionary new];
    for (NSString *name in library.functionNames) shaderInputs[name] = copy;
    shaderInputBytes += size;
}

static NSMutableDictionary *RenderRecord(MTLRenderPipelineDescriptor *descriptor, MTLPipelineOption options) {
    NSMutableArray *colors = [NSMutableArray new];
    NSMutableArray *vertexBuffers = [NSMutableArray new], *fragmentBuffers = [NSMutableArray new];
    for (NSUInteger i = 0; i < 8; ++i) {
        MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[i];
        [colors addObject:@{@"pixelFormat": @(color.pixelFormat), @"writeMask": @(color.writeMask), @"blendingEnabled": @(color.blendingEnabled), @"rgbBlendOperation": @(color.rgbBlendOperation), @"alphaBlendOperation": @(color.alphaBlendOperation), @"sourceRGBBlendFactor": @(color.sourceRGBBlendFactor), @"destinationRGBBlendFactor": @(color.destinationRGBBlendFactor), @"sourceAlphaBlendFactor": @(color.sourceAlphaBlendFactor), @"destinationAlphaBlendFactor": @(color.destinationAlphaBlendFactor)}];
    }
    for (NSUInteger i = 0; i < 31; ++i) {
        [vertexBuffers addObject:@(descriptor.vertexBuffers[i].mutability)];
        [fragmentBuffers addObject:@(descriptor.fragmentBuffers[i].mutability)];
    }
    NSString *vertex = descriptor.vertexFunction.name ?: @"";
    NSString *fragment = descriptor.fragmentFunction.name ?: @"";
    NSMutableDictionary *record = [@{@"schemaVersion": @1, @"error": @"", @"vertexFunction": vertex, @"fragmentFunction": fragment, @"rasterSampleCount": @(descriptor.rasterSampleCount), @"depthAttachmentPixelFormat": @(descriptor.depthAttachmentPixelFormat), @"stencilAttachmentPixelFormat": @(descriptor.stencilAttachmentPixelFormat), @"inputPrimitiveTopology": @(descriptor.inputPrimitiveTopology), @"rasterizationEnabled": @(descriptor.rasterizationEnabled), @"alphaToCoverageEnabled": @(descriptor.alphaToCoverageEnabled), @"alphaToOneEnabled": @(descriptor.alphaToOneEnabled), @"supportIndirectCommandBuffers": @(descriptor.supportIndirectCommandBuffers), @"vertexBuffers": vertexBuffers, @"fragmentBuffers": fragmentBuffers, @"colorAttachments": colors, @"vertexDescriptorPresent": @(descriptor.vertexDescriptor != nil), @"vertexLibraryCaptured": @(shaderInputs[vertex] != nil), @"fragmentLibraryCaptured": @(shaderInputs[fragment] != nil)} mutableCopy];
    record[@"maxVertexAmplificationCount"] = @(descriptor.maxVertexAmplificationCount);
    record[@"pipelineOptions"] = @(options);
    record[@"maxVertexCallStackDepth"] = @(descriptor.maxVertexCallStackDepth);
    record[@"maxFragmentCallStackDepth"] = @(descriptor.maxFragmentCallStackDepth);
    if (descriptor.vertexDescriptor) {
        NSMutableArray *attributes = [NSMutableArray new], *layouts = [NSMutableArray new];
        for (NSUInteger i = 0; i < 31; ++i) {
            MTLVertexAttributeDescriptor *attribute = descriptor.vertexDescriptor.attributes[i];
            MTLVertexBufferLayoutDescriptor *layout = descriptor.vertexDescriptor.layouts[i];
            [attributes addObject:@{@"format": @(attribute.format), @"offset": @(attribute.offset), @"bufferIndex": @(attribute.bufferIndex)}];
            [layouts addObject:@{@"stride": @(layout.stride), @"stepFunction": @(layout.stepFunction), @"stepRate": @(layout.stepRate)}];
        }
        record[@"vertexDescriptor"] = @{@"attributes": attributes, @"layouts": layouts};
    }
    return record;
}

static void ExportFailedRender(MTLRenderPipelineDescriptor *descriptor, NSError *error, MTLPipelineOption options = MTLPipelineOptionNone) {
    if ((error.code != 2 || ![error.domain hasPrefix:@"AGX"]) &&
        ![error.domain isEqual:@"org.avpplay.offline-pipeline"]) return;
    std::lock_guard<std::mutex> lock(failureMutex);
    if (failureExported) return;
    NSMutableDictionary *record = RenderRecord(descriptor, options);
    NSData *keyData = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    NSString *key = [keyData base64EncodedStringWithOptions:0];
    if (!key) return;
    if (!exportedPipelineKeys) exportedPipelineKeys = [NSMutableSet new];
    if ([exportedPipelineKeys containsObject:key]) return;
    if (exportedPipelineKeys.count >= 16) { failureExported = true; return; }
    NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [[documents URLByAppendingPathComponent:@"WindowsVR/CompilerFailures" isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    if (!directory || ![[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]) return;
    record[@"error"] = error.localizedDescription ?: @"";
    NSString *vertex = descriptor.vertexFunction.name ?: @"";
    NSString *fragment = descriptor.fragmentFunction.name ?: @"";
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:nil];
    NSUInteger bytes = json.length + shaderInputs[vertex].length + shaderInputs[fragment].length;
    if (bytes > 16 * 1024 * 1024 - exportedPipelineBytes) { failureExported = true; return; }
    [exportedPipelineKeys addObject:key];
    exportedPipelineBytes += bytes;
    [json writeToURL:[directory URLByAppendingPathComponent:@"render-pipeline.json"] options:NSDataWritingAtomic error:nil];
    [shaderInputs[vertex] writeToURL:[directory URLByAppendingPathComponent:@"vertex.metallib"] options:NSDataWritingAtomic error:nil];
    [shaderInputs[fragment] writeToURL:[directory URLByAppendingPathComponent:@"fragment.metallib"] options:NSDataWritingAtomic error:nil];
    NSLog(@"[WVR Metal] failed render pipeline exported %@ (%lu/16)", directory.lastPathComponent, (unsigned long)exportedPipelineKeys.count);
}

int wvr_metal_copy_compiler_failure(char *buffer, uint32_t capacity) {
    std::lock_guard<std::mutex> lock(failureMutex);
    if (!compilerFailure || !buffer || !capacity) return 0;
    snprintf(buffer, capacity, "%s", compilerFailure.UTF8String);
    return 1;
}
static void RecordCompilerFailure(NSError *error) {
    if (error.code != 2 || ![error.domain hasPrefix:@"AGX"]) return;
    std::lock_guard<std::mutex> lock(failureMutex);
    if (!compilerFailure) compilerFailure = [@"The Metal shader compiler crashed while compiling the game's graphics. A session exit was requested to prevent repeated faults and audio lag. Restart the app before retrying." copy];
}

static NSString *DataSHA256(NSData *data) {
    if (!data) return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, CC_LONG(data.length), digest);
    NSMutableString *hash = [NSMutableString string];
    for (unsigned char byte : digest) [hash appendFormat:@"%02x", byte];
    return hash;
}

// Only use an archive for the exact captured shader inputs and descriptor.
// A matching entry that fails validation must not silently fall back to the
// on-device compiler that has already crashed for this pipeline.
static int PrepareArchivedRender(MTLRenderPipelineDescriptor *descriptor, MTLPipelineOption options,
                                 MTLRenderPipelineDescriptor **prepared, NSError **error) {
    for (NSDictionary *entry in offlinePipelines) {
        NSDictionary *expected = entry[@"descriptor"];
        if (![expected[@"vertexFunction"] isEqual:descriptor.vertexFunction.name] ||
            ![expected[@"fragmentFunction"] isEqual:descriptor.fragmentFunction.name]) continue;
        std::lock_guard<std::mutex> lock(failureMutex);
        NSMutableDictionary *actual = RenderRecord(descriptor, options);
        [actual removeObjectsForKeys:@[@"error", @"schemaVersion", @"vertexLibraryCaptured", @"fragmentLibraryCaptured"]];
        BOOL matches = [actual isEqualToDictionary:expected] &&
            [DataSHA256(shaderInputs[descriptor.vertexFunction.name]) isEqual:entry[@"vertexSHA256"]] &&
            [DataSHA256(shaderInputs[descriptor.fragmentFunction.name]) isEqual:entry[@"fragmentSHA256"]];
        id<MTLBinaryArchive> archive = entry[@"loadedArchive"];
        if (!matches || !archive) {
            NSString *detail = @"The offline shader archive did not match this pipeline or could not load. Runtime compilation was blocked for the known failing shader pair.";
            if (!compilerFailure) compilerFailure = [detail copy];
            *error = [NSError errorWithDomain:@"org.avpplay.offline-pipeline" code:1 userInfo:@{NSLocalizedDescriptionKey: detail}];
            return -1;
        }
        *prepared = [descriptor copy];
        NSMutableArray *archives = [NSMutableArray arrayWithObject:archive];
        [archives addObjectsFromArray:descriptor.binaryArchives ?: @[]];
        (*prepared).binaryArchives = archives;
        return 1;
    }
    return 0;
}

static void LoadOfflinePipelines(id<MTLDevice> device) {
    NSURL *root = [NSBundle.mainBundle URLForResource:@"WindowsVROfflinePipelines" withExtension:nil];
    NSData *data = [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"index.json"]];
    if (!data || data.length > 1024 * 1024) return;
    id entries = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![entries isKindOfClass:NSArray.class] || [entries count] > 32) return;
    NSMutableArray *loaded = [NSMutableArray new];
    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"descriptor"] isKindOfClass:NSDictionary.class]) continue;
        NSString *name = entry[@"archive"];
        if (![name isKindOfClass:NSString.class] || ![name.lastPathComponent isEqual:name]) continue;
        NSURL *url = [root URLByAppendingPathComponent:name];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
        if ([attrs[NSFileSize] unsignedLongLongValue] > 8 * 1024 * 1024) continue;
        NSMutableDictionary *record = [entry mutableCopy];
        NSError *error = nil;
        if ([DataSHA256([NSData dataWithContentsOfURL:url]) isEqual:entry[@"archiveSHA256"]]) {
            MTLBinaryArchiveDescriptor *archiveDescriptor = [MTLBinaryArchiveDescriptor new];
            archiveDescriptor.url = url;
            id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
            if (archive) record[@"loadedArchive"] = archive;
        }
        [loaded addObject:record];
        NSLog(@"[WVR Metal] offline archive %@ loaded=%d error=%@", name, record[@"loadedArchive"] != nil, error);
    }
    offlinePipelines = [loaded copy];
}

static uint16_t Read16(const uint8_t *bytes) {
    return uint16_t(bytes[0]) | (uint16_t(bytes[1]) << 8);
}
static uint64_t Read64(const uint8_t *bytes) {
    uint64_t value = 0;
    for (unsigned i = 0; i < 8; ++i) value |= uint64_t(bytes[i]) << (8 * i);
    return value;
}
static void Write16(uint8_t *bytes, uint16_t value) {
    bytes[0] = uint8_t(value); bytes[1] = uint8_t(value >> 8);
}
static void Write32(uint8_t *bytes, uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) bytes[i] = uint8_t(value >> (8 * i));
}
static void Write64(uint8_t *bytes, uint64_t value) {
    for (unsigned i = 0; i < 8; ++i) bytes[i] = uint8_t(value >> (8 * i));
}

// The prebuilt DXMT writer labels Metal 3.2/AIR 2.7 shaders as 3.1/2.6.
// Its generator target must also be repaired to xros2.0 (see the prebuilt
// repair script). Xros's raw BC payload also needs the Darwin bitcode wrapper
// emitted by Apple's linker. The local legacy writer already targets xros2;
// both known xros1/xros2 inputs need this same container correction. Preserve
// the IR bytes and update container sizes
// and hashes to describe the wrapped payload.
static dispatch_data_t CorrectContainerVersions(dispatch_data_t input) {
    const void *mappedBytes = nullptr;
    size_t size = 0;
    dispatch_data_t mapped = dispatch_data_create_map(input, &mappedBytes, &size);
    if (!mapped || !mappedBytes || size < 96 || size > 8 * 1024 * 1024) return input;
    const uint8_t *bytes = (const uint8_t *)mappedBytes;
    if (memcmp(bytes, "MTLB", 4) || Read16(bytes + 4) != 1 || bytes[11] != 0x8b ||
        Read16(bytes + 6) != 2 || Read16(bytes + 8) != 7 ||
        (Read16(bytes + 12) != 1 && Read16(bytes + 12) != 2) ||
        Read64(bytes + 16) != size) return input;
    uint64_t offset = Read64(bytes + 24), sectionSize = Read64(bytes + 32);
    uint64_t bitcodeOffset = Read64(bytes + 72), bitcodeSize = Read64(bytes + 80);
    if (offset > size - 8 || sectionSize > size - offset || bitcodeOffset > size ||
        bitcodeSize != size - bitcodeOffset || bitcodeSize < 4 ||
        memcmp(bytes + bitcodeOffset, "BC\xc0\xde", 4)) return input;
    // Only the known, single-function DXMT-generated libraries are eligible.
    if (bytes[offset] != 1 || bytes[offset + 1] || bytes[offset + 2] || bytes[offset + 3]) return input;
    size_t versionOffset = 0, hashOffset = 0, sizeOffset = 0;
    for (size_t cursor = size_t(offset) + 8; cursor + 6 <= size_t(offset + sectionSize);) {
        if (!memcmp(bytes + cursor, "ENDT", 4)) break;
        uint16_t length = Read16(bytes + cursor + 4);
        if (length > size_t(offset + sectionSize) - cursor - 6) return input;
        if (!memcmp(bytes + cursor, "VERS", 4) && length == 8 &&
            Read16(bytes + cursor + 6) == 2 && Read16(bytes + cursor + 8) == 6 &&
            Read16(bytes + cursor + 10) == 3 && Read16(bytes + cursor + 12) == 1) {
            versionOffset = cursor;
        }
        if (!memcmp(bytes + cursor, "HASH", 4) && length == 32) hashOffset = cursor + 6;
        if (!memcmp(bytes + cursor, "MDSZ", 4) && length == 8) sizeOffset = cursor + 6;
        cursor += 6 + length;
    }
    if (!versionOffset || !hashOffset || !sizeOffset) return input;
    const void *payload = bytes + bitcodeOffset;
    size_t payloadSize = size_t(bitcodeSize);
    const size_t wrappedSize = (20 + payloadSize + 15) & ~size_t(15);
    NSMutableData *copy = [NSMutableData dataWithLength:size_t(bitcodeOffset) + wrappedSize];
    uint8_t *output = (uint8_t *)copy.mutableBytes;
    memcpy(output, bytes, size_t(bitcodeOffset));
    uint8_t *wrapper = output + bitcodeOffset;
    Write32(wrapper, 0x0b17c0de);
    Write32(wrapper + 4, 0); // Wrapper version.
    Write32(wrapper + 8, 20); // Offset to the original, unchanged LLVM bitcode.
    Write32(wrapper + 12, uint32_t(payloadSize));
    Write32(wrapper + 16, UINT32_MAX); // AIR has no Mach-O CPU architecture.
    memcpy(wrapper + 20, payload, payloadSize);
    Write64(output + 16, copy.length);
    Write64(output + 80, wrappedSize);
    Write64(output + sizeOffset, wrappedSize);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(wrapper, CC_LONG(wrappedSize), digest);
    memcpy(output + hashOffset, digest, sizeof(digest));
    Write16(output + 12, 2); // Minimum shader target, not the app's visionOS 27 target.
    Write16(output + versionOffset + 8, 7);
    Write16(output + versionOffset + 12, 2);
    return dispatch_data_create(copy.bytes, copy.length, nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
}

static void WriteJSON(NSDictionary *value, NSString *name) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    if (json) [json writeToURL:[captureDirectory URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
}

static void CaptureLibrary(dispatch_data_t input, id<MTLLibrary> library, NSError *error) {
    if (!captureEnabled) return;
    [captureLock lock];
    BOOL full = capturedHashes.count >= 32;
    [captureLock unlock];
    if (full) return;
    const void *bytes = nullptr;
    size_t length = 0;
    dispatch_data_t mapped = dispatch_data_create_map(input, &bytes, &length);
    // Bound disk and memory costs; never copy arbitrarily large game data.
    if (!mapped || !bytes || !length || length > 8 * 1024 * 1024) return;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)length, digest);
    NSMutableString *hash = [NSMutableString string];
    for (unsigned char byte : digest) [hash appendFormat:@"%02x", byte];
    [captureLock lock];
    if (capturedHashes.count < 32 && ![capturedHashes containsObject:hash]) {
        [capturedHashes addObject:hash];
        NSData *data = [NSData dataWithBytes:bytes length:length];
        [data writeToURL:[captureDirectory URLByAppendingPathComponent:[hash stringByAppendingString:@".metallib"]] options:NSDataWritingAtomic error:nil];
        WriteJSON(@{@"sha256": hash, @"length": @(length), @"functions": library.functionNames ?: @[], @"error": error.localizedDescription ?: @"", @"libraryCreated": @(library != nil)}, [hash stringByAppendingString:@".json"]);
        NSLog(@"[WVR Metal] shader %@ bytes=%zu library=%d", hash, length, library != nil);
    }
    [captureLock unlock];
}
static void CaptureFailure(NSString *stage, NSArray *functions, NSError *error) {
    if (!captureEnabled) return;
    [captureLock lock];
    if (failureCount < 32) {
        NSUInteger index = ++failureCount;
        WriteJSON(@{@"stage": stage, @"functions": functions, @"error": error.localizedDescription ?: @"No error supplied", @"domain": error.domain ?: @"", @"code": @(error.code)}, [NSString stringWithFormat:@"pipeline-%02lu.json", (unsigned long)index]);
        NSLog(@"[WVR Metal] %@ pipeline failed functions=%@ error=%@", stage, functions, error);
    }
    [captureLock unlock];
}
static id NewLibrary(id device, SEL selector, dispatch_data_t data, NSError **error) NS_RETURNS_RETAINED;
static id NewLibrary(id device, SEL selector, dispatch_data_t data, NSError **error) {
    NSError *localError = nil;
#if WVR_SOURCE_AIR_WRITER
    dispatch_data_t prepared = data;
    const void *bytes = nullptr;
    size_t size = 0;
    dispatch_data_t mapped = data ? dispatch_data_create_map(data, &bytes, &size) : nil;
    uint8_t *output = nullptr;
    size_t outputLength = 0;
    char reason[1024] = {};
    int result = mapped ? wvr_air_reemit((const uint8_t *)bytes, size, &output, &outputLength, reason, sizeof(reason)) : 0;
    if (result < 0) {
        NSString *detail = [NSString stringWithUTF8String:reason] ?: @"Invalid generated shader library";
        localError = [NSError errorWithDomain:@"org.avpplay.air-writer" code:1 userInfo:@{NSLocalizedDescriptionKey: detail}];
        { std::lock_guard<std::mutex> lock(failureMutex);
          if (!compilerFailure) compilerFailure = [[@"Shader preparation failed: " stringByAppendingString:detail] copy]; }
        if (error) *error = localError;
        return nil;
    }
    if (result > 0) {
        // DEFAULT copies the bytes; release our source writer's allocation now.
        prepared = dispatch_data_create(output, outputLength, nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        free(output);
    }
#else
    dispatch_data_t prepared = data ? CorrectContainerVersions(data) : data;
#endif
    id<MTLLibrary> library = originalLibrary(device, selector, prepared, &localError);
    RememberShaderInput(prepared, library);
    if (error) *error = localError;
    if (prepared) CaptureLibrary(prepared, library, localError);
    return library;
}
static id NewRender(id device, SEL selector, MTLRenderPipelineDescriptor *descriptor, NSError **error) NS_RETURNS_RETAINED;
static id NewRenderOptions(id device, SEL selector, MTLRenderPipelineDescriptor *descriptor, MTLPipelineOption options, MTLRenderPipelineReflection **reflection, NSError **error) NS_RETURNS_RETAINED;
static id NewRender(id device, SEL selector, MTLRenderPipelineDescriptor *descriptor, NSError **error) {
    if (offlinePipelines.count && originalRenderOptions) {
        return NewRenderOptions(device, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:), descriptor, MTLPipelineOptionNone, nullptr, error);
    }
    NSError *localError = nil;
    id pipeline = originalRender(device, selector, descriptor, &localError);
    if (error) *error = localError;
    if (!pipeline) { ExportFailedRender(descriptor, localError); RecordCompilerFailure(localError); }
    if (!pipeline) CaptureFailure(@"render", @[descriptor.vertexFunction.name ?: @"<nil vertex>", descriptor.fragmentFunction.name ?: @"<nil fragment>"], localError);
    return pipeline;
}
static id NewCompute(id device, SEL selector, MTLComputePipelineDescriptor *descriptor, MTLPipelineOption options, MTLComputePipelineReflection **reflection, NSError **error) NS_RETURNS_RETAINED;
static id NewRenderOptions(id device, SEL selector, MTLRenderPipelineDescriptor *descriptor, MTLPipelineOption options, MTLRenderPipelineReflection **reflection, NSError **error) NS_RETURNS_RETAINED;
static id NewRenderOptions(id device, SEL selector, MTLRenderPipelineDescriptor *descriptor, MTLPipelineOption options, MTLRenderPipelineReflection **reflection, NSError **error) {
    NSError *localError = nil;
    MTLRenderPipelineDescriptor *prepared = descriptor;
    int archived = PrepareArchivedRender(descriptor, options, &prepared, &localError);
    id pipeline = archived < 0 ? nil : originalRenderOptions(device, selector, prepared,
        archived > 0 ? options | MTLPipelineOptionFailOnBinaryArchiveMiss : options, reflection, &localError);
    if (archived > 0) {
        NSLog(@"[WVR Metal] offline pipeline %@/%@ hit=%d", descriptor.vertexFunction.name, descriptor.fragmentFunction.name, pipeline != nil);
        if (!pipeline) {
            std::lock_guard<std::mutex> lock(failureMutex);
            if (!compilerFailure) compilerFailure = [@"Metal could not use the offline shader archive. Runtime compilation was blocked for this pipeline." copy];
        }
    }
    if (error) *error = localError;
    if (!pipeline) {
        ExportFailedRender(descriptor, localError, options);
        RecordCompilerFailure(localError);
        CaptureFailure(@"render", @[descriptor.vertexFunction.name ?: @"<nil vertex>", descriptor.fragmentFunction.name ?: @"<nil fragment>"], localError);
    }
    return pipeline;
}
static id NewCompute(id device, SEL selector, MTLComputePipelineDescriptor *descriptor, MTLPipelineOption options, MTLComputePipelineReflection **reflection, NSError **error) {
    NSError *localError = nil;
    id pipeline = originalCompute(device, selector, descriptor, options, reflection, &localError);
    if (error) *error = localError;
    if (!pipeline) RecordCompilerFailure(localError);
    if (!pipeline) CaptureFailure(@"compute", @[descriptor.computeFunction.name ?: @"<nil compute>"], localError);
    return pipeline;
}
static IMP Install(Class deviceClass, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(deviceClass, selector);
    if (!method) return nullptr;
    IMP original = method_getImplementation(method);
    // Add an override for inherited methods rather than replacing the superclass.
    if (!class_addMethod(deviceClass, selector, replacement, method_getTypeEncoding(method))) {
        class_replaceMethod(deviceClass, selector, replacement, method_getTypeEncoding(method));
    }
    return original;
}
void wvr_metal_shader_compatibility_install(int capture) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return;
        LoadOfflinePipelines(device);
        captureEnabled = capture != 0;
        captureLock = [NSLock new];
        capturedHashes = [NSMutableSet new];
        NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        captureDirectory = [[documents URLByAppendingPathComponent:@"WindowsVR/MetalDiagnostics" isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        if (captureEnabled && (!captureDirectory || ![[NSFileManager defaultManager] createDirectoryAtURL:captureDirectory withIntermediateDirectories:YES attributes:nil error:nil])) {
            // Disk diagnostics must never prevent the compatibility repair.
            captureEnabled = false;
        }
        Class cls = object_getClass(device);
        // Publish original implementations before exposing replacement methods
        // to the already-running compositor thread.
        Method libraryMethod = class_getInstanceMethod(cls, @selector(newLibraryWithData:error:));
        Method renderMethod = class_getInstanceMethod(cls, @selector(newRenderPipelineStateWithDescriptor:error:));
        Method renderOptionsMethod = class_getInstanceMethod(cls, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:));
        Method computeMethod = class_getInstanceMethod(cls, @selector(newComputePipelineStateWithDescriptor:options:reflection:error:));
        if (libraryMethod) originalLibrary = (LibraryIMP)method_getImplementation(libraryMethod);
        if (renderMethod) originalRender = (RenderIMP)method_getImplementation(renderMethod);
        if (renderOptionsMethod) originalRenderOptions = (RenderOptionsIMP)method_getImplementation(renderOptionsMethod);
        if (computeMethod) originalCompute = (ComputeIMP)method_getImplementation(computeMethod);
        if (originalLibrary) Install(cls, @selector(newLibraryWithData:error:), (IMP)NewLibrary);
        if (originalRender) Install(cls, @selector(newRenderPipelineStateWithDescriptor:error:), (IMP)NewRender);
        if (originalRenderOptions) Install(cls, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:), (IMP)NewRenderOptions);
        if (originalCompute) Install(cls, @selector(newComputePipelineStateWithDescriptor:options:reflection:error:), (IMP)NewCompute);
        NSLog(@"[WVR Metal] compatibility installed device=%@ library=%d render=%d renderOptions=%d compute=%d capture=%d sourceWriter=%d", device.name, originalLibrary != nullptr, originalRender != nullptr, originalRenderOptions != nullptr, originalCompute != nullptr, captureEnabled, WVR_SOURCE_AIR_WRITER);
    });
}

// Public Metal commit/completion observation. Enabled for diagnosis, with bounded
// pending storage and no GPU waits, captures, readbacks or scheduling changes.
namespace {
struct GPUCounts { uint64_t submitted=0,completed=0,failed=0,timed=0; double gpuMS=0,queueMS=0; };
enum class GPUStage { Guest, Snapshot, Presentation };
struct GPUPending { double time; GPUStage stage; };
std::mutex gpuStatisticsMutex;
GPUCounts guestGPU, snapshotGPU, presentationGPU;
GPUCounts previousGuestGPU, previousSnapshotGPU, previousPresentationGPU;
GPUCounts& CountsForStage(GPUStage stage) {
    switch(stage) {
        case GPUStage::Snapshot: return snapshotGPU;
        case GPUStage::Presentation: return presentationGPU;
        default: return guestGPU;
    }
}
// Fixed slots avoid an allocation/free for every observed command buffer.
struct PendingGPUStorage {
    std::array<GPUPending, 4096> entries{};
    std::array<size_t, 4096> freeSlots{};
    size_t freeCount = entries.size();
    PendingGPUStorage() {
        for (size_t i = 0; i < freeSlots.size(); ++i) freeSlots[i] = i;
    }
} pendingGPU;
uint64_t pendingOverflow=0;
typedef void (*CommitIMP)(id,SEL);
CommitIMP originalCommit=nullptr;
// Metal GPU timestamps and mach_absolute_time use seconds since boot.
double GPUClock() {
    static const double factor=[] {
        mach_timebase_info_data_t info{}; mach_timebase_info(&info);
        return static_cast<double>(info.numer)/info.denom/1e9;
    }();
    return static_cast<double>(mach_absolute_time())*factor;
}
void ObserveCommit(id object,SEL selector) {
    id<MTLCommandBuffer> buffer=object;
    const GPUStage stage=[buffer.label hasPrefix:@"wvr.presentation"] ? GPUStage::Presentation :
        ([buffer.label hasPrefix:@"wvr.snapshot"] ? GPUStage::Snapshot : GPUStage::Guest);
    const double committedAt=GPUClock();
    size_t slot = pendingGPU.entries.size();
    {
        std::lock_guard<std::mutex> lock(gpuStatisticsMutex);
        CountsForStage(stage).submitted++;
        if (pendingGPU.freeCount) {
            slot = pendingGPU.freeSlots[--pendingGPU.freeCount];
            pendingGPU.entries[slot] = {committedAt, stage};
        } else pendingOverflow++;
    }
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        std::lock_guard<std::mutex> lock(gpuStatisticsMutex);
        auto& counts=CountsForStage(stage);
        counts.completed++;
        if(completed.status==MTLCommandBufferStatusError) counts.failed++;
        const double duration=completed.GPUEndTime-completed.GPUStartTime;
        if(completed.GPUStartTime>0 && duration>=0){
            counts.timed++; counts.gpuMS+=duration*1000;
            counts.queueMS+=std::max(0.0,completed.GPUStartTime-committedAt)*1000;
        }
        if (slot < pendingGPU.entries.size()) {
            pendingGPU.entries[slot].time = 0;
            pendingGPU.freeSlots[pendingGPU.freeCount++] = slot;
        }
    }];
    originalCommit(object,selector);
}
}
void wvr_metal_gpu_statistics_install(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue=[device newCommandQueue];
        id<MTLCommandBuffer> buffer=[queue commandBuffer];
        if(!buffer) return;
        originalCommit=(CommitIMP)Install(object_getClass(buffer),@selector(commit),(IMP)ObserveCommit);
        NSLog(@"[WVR GPU] commit observer class=%@ enabled=%d",NSStringFromClass(object_getClass(buffer)),originalCommit!=nullptr);
    });
}
int wvr_metal_copy_gpu_statistics(char *buffer,uint32_t capacity) {
    if(!buffer || !capacity) return 0;
    GPUCounts guest, snapshot, presentation, previousGuest, previousSnapshot, previousPresentation;
    double guestAge=0,snapshotAge=0,presentationAge=0;
    uint64_t overflow=0;
    {
        std::lock_guard<std::mutex> lock(gpuStatisticsMutex);
        if(!originalCommit){buffer[0]=0;return 0;}
        const double now=GPUClock();
        for (const auto& record : pendingGPU.entries) {
            if (!record.time) continue;
            auto& age=record.stage==GPUStage::Presentation?presentationAge:(record.stage==GPUStage::Snapshot?snapshotAge:guestAge);
            age=std::max(age,now-record.time);
        }
        guest=guestGPU; snapshot=snapshotGPU; presentation=presentationGPU;
        previousGuest=previousGuestGPU; previousSnapshot=previousSnapshotGPU; previousPresentation=previousPresentationGPU;
        previousGuestGPU=guestGPU; previousPresentationGPU=presentationGPU; previousSnapshotGPU=snapshotGPU;
        overflow=pendingOverflow;
    } // Formatting cannot block commit/completion bookkeeping.
    auto windowGPU=[](const GPUCounts& counts,const GPUCounts& previous) {
        const uint64_t timed=counts.timed-previous.timed;
        return timed ? (counts.gpuMS-previous.gpuMS)/timed : 0.0;
    };
    auto windowQueue=[](const GPUCounts& counts,const GPUCounts& previous) {
        const uint64_t timed=counts.timed-previous.timed;
        return timed ? (counts.queueMS-previous.queueMS)/timed : 0.0;
    };
    std::snprintf(buffer,capacity,"guest submitted=%llu completed=%llu failed=%llu meanGPUms=%.3f oldestPending=%.3fs | presentation submitted=%llu completed=%llu failed=%llu meanGPUms=%.3f oldestPending=%.3fs | snapshot submitted=%llu completed=%llu failed=%llu meanGPUms=%.3f oldestPending=%.3fs | untracked=%llu | window guest GPUms=%.3f queueMs=%.3f presentation GPUms=%.3f queueMs=%.3f snapshot GPUms=%.3f queueMs=%.3f",
        (unsigned long long)guest.submitted,(unsigned long long)guest.completed,(unsigned long long)guest.failed,guest.timed?guest.gpuMS/guest.timed:0,guestAge,
        (unsigned long long)presentation.submitted,(unsigned long long)presentation.completed,(unsigned long long)presentation.failed,presentation.timed?presentation.gpuMS/presentation.timed:0,presentationAge,
        (unsigned long long)snapshot.submitted,(unsigned long long)snapshot.completed,(unsigned long long)snapshot.failed,snapshot.timed?snapshot.gpuMS/snapshot.timed:0,snapshotAge,(unsigned long long)overflow,
        windowGPU(guest,previousGuest),windowQueue(guest,previousGuest),
        windowGPU(presentation,previousPresentation),windowQueue(presentation,previousPresentation),
        windowGPU(snapshot,previousSnapshot),windowQueue(snapshot,previousSnapshot));
    return 1;
}
