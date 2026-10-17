#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <openvr_capi.h>
#include <stdio.h>
#include <stdarg.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <wchar.h>

/* Stable C function-table prefixes for OpenComposite's pinned OpenVR versions.
 * Only scalar/pointer methods are called; no C++ vtable/aggregate-return ABI. */
typedef struct {
    void (__stdcall *recommended)(uint32_t*,uint32_t*);
    void *projectionMatrix;
    void (__stdcall *projectionRaw)(EVREye,float*,float*,float*,float*);
} System017;
typedef struct {
    void (__stdcall *setTrackingSpace)(ETrackingUniverseOrigin);
    void *getTrackingSpace;
    EVRCompositorError (__stdcall *waitPoses)(TrackedDevicePose_t*,uint32_t,TrackedDevicePose_t*,uint32_t);
    void *lastPoses,*lastPose;
    EVRCompositorError (__stdcall *submit)(EVREye,Texture_t*,VRTextureBounds_t*,EVRSubmitFlags);
} Compositor021;
_Static_assert(sizeof(TrackedDevicePose_t)==80,"OpenVR Windows pose packing");
#ifdef _WIN64
_Static_assert(sizeof(Texture_t)==16,"OpenVR Win64 texture packing");
#define WVR_OPENVR_DLL L"\\bin\\vrclient_x64.dll"
#define WVR_OPENXR_REGISTRY_VIEW KEY_WOW64_64KEY
#else
_Static_assert(sizeof(Texture_t)==12,"OpenVR Win32 texture packing");
#define WVR_OPENVR_DLL L"\\bin\\vrclient.dll"
#define WVR_OPENXR_REGISTRY_VIEW KEY_WOW64_32KEY
#endif

typedef uint32_t (__cdecl *InitFn)(EVRInitError*,EVRApplicationType,const char*);
typedef void* (__cdecl *InterfaceFn)(const char*,EVRInitError*);
typedef void (__cdecl *ShutdownFn)(void);
static FILE *logfile;
static volatile int running=1;
static void logline(const char *format,...) {
    if(!logfile)return;
    va_list args;va_start(args,format);vfprintf(logfile,format,args);va_end(args);
    fputc('\n',logfile);fflush(logfile);
}
static int fail(const char *operation,long code) {
    char message[256];snprintf(message,sizeof(message),"%s failed: 0x%08lx",operation,(unsigned long)code);
    logline("ERROR %s",message);OutputDebugStringA(message);return 1;
}
static LRESULT CALLBACK windowProc(HWND window,UINT message,WPARAM w,LPARAM l) {
    if(message==WM_CLOSE){running=0;DestroyWindow(window);return 0;}
    if(message==WM_DESTROY){running=0;PostQuitMessage(0);return 0;}
    if(message==WM_KEYDOWN&&w==VK_ESCAPE){running=0;return 0;}
    return DefWindowProcW(window,message,w,l);
}
/* This key belongs to the app-owned Wine prefix, never the Mac registry.
 * The official Windows loader deliberately ignores env overrides at HIGH
 * integrity. Register only our validated private manifest and restore it. */
static HKEY runtimeKey;
static BYTE *priorRuntime;
static DWORD priorSize,priorType;
static int hadPrior,registeredRuntime;
static wchar_t registeredPath[32768];
static void restoreRuntimeRegistration(void) {
    if(runtimeKey&&registeredRuntime){
        DWORD type=0,size=0;LONG result=RegQueryValueExW(runtimeKey,L"ActiveRuntime",NULL,&type,NULL,&size);
        DWORD ours=(DWORD)((wcslen(registeredPath)+1)*sizeof(wchar_t));
        wchar_t current[32768];
        if(result==ERROR_SUCCESS&&type==REG_SZ&&size==ours&&size<=sizeof(current)&&
           RegQueryValueExW(runtimeKey,L"ActiveRuntime",NULL,&type,(BYTE*)current,&size)==ERROR_SUCCESS&&
           memcmp(current,registeredPath,ours)==0){
            result=hadPrior?RegSetValueExW(runtimeKey,L"ActiveRuntime",0,priorType,priorRuntime,priorSize):RegDeleteValueW(runtimeKey,L"ActiveRuntime");
            logline("runtime registry restored=%d previousValue=%d error=%ld",result==ERROR_SUCCESS,hadPrior,(long)result);
        } else logline("runtime registry restoration skipped: value changed externally");
    }
    if(runtimeKey)RegCloseKey(runtimeKey);
    runtimeKey=NULL;registeredRuntime=0;free(priorRuntime);priorRuntime=NULL;
}
static int configureRuntime(const wchar_t *override) {
    const wchar_t suffix[]=L"\\OpenComposite";
    size_t length=wcslen(override),suffixLength=wcslen(suffix);
    if(length<=suffixLength||length>=32600||wcsncmp(override,L"C:\\windows-vr-runtime\\",22)!=0||
       wcsstr(override,L"..")||wcscmp(override+length-suffixLength,suffix)!=0)
        return fail("Private VR_OVERRIDE path invalid",ERROR_INVALID_NAME);
    wchar_t manifest[32768],dll[32768];
    wmemcpy(manifest,override,length-suffixLength);manifest[length-suffixLength]=0;wcscat(manifest,L"\\runtime.json");
    wmemcpy(dll,override,length-suffixLength);dll[length-suffixLength]=0;wcscat(dll,L"\\wvr_openxr.dll");
    DWORD mf=GetFileAttributesW(manifest),df=GetFileAttributesW(dll);
    if(mf==INVALID_FILE_ATTRIBUTES||df==INVALID_FILE_ATTRIBUTES||(mf&FILE_ATTRIBUTE_DIRECTORY)||(df&FILE_ATTRIBUTE_DIRECTORY))
        return fail("Private runtime manifest/DLL missing",GetLastError());
    DWORD previousEnv=GetEnvironmentVariableW(L"XR_RUNTIME_JSON",NULL,0);
    logline("Windows XR_RUNTIME_JSON present=%d chars=%lu",previousEnv!=0,(unsigned long)previousEnv);
    if(!SetEnvironmentVariableW(L"XR_RUNTIME_JSON",manifest))return fail("Set Windows XR_RUNTIME_JSON",GetLastError());
    HANDLE token=NULL;_Alignas(TOKEN_MANDATORY_LABEL) BYTE buffer[1024];DWORD needed=0;
    if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return fail("OpenProcessToken",GetLastError());
    BOOL queried=GetTokenInformation(token,TokenIntegrityLevel,buffer,sizeof(buffer),&needed);DWORD tokenError=GetLastError();CloseHandle(token);
    if(!queried)return fail("TokenIntegrityLevel",tokenError);
    TOKEN_MANDATORY_LABEL *label=(TOKEN_MANDATORY_LABEL*)buffer;
    if(!IsValidSid(label->Label.Sid)||!*GetSidSubAuthorityCount(label->Label.Sid))return fail("Token integrity SID",ERROR_INVALID_SID);
    DWORD rid=*GetSidSubAuthority(label->Label.Sid,*GetSidSubAuthorityCount(label->Label.Sid)-1);
    logline("Windows token integrity RID=0x%lx; secure env ignored=%d",(unsigned long)rid,rid>SECURITY_MANDATORY_MEDIUM_RID);
    if(rid<=SECURITY_MANDATORY_MEDIUM_RID)return 0;
    LONG result=RegCreateKeyExW(HKEY_LOCAL_MACHINE,L"SOFTWARE\\Khronos\\OpenXR\\1",0,NULL,0,KEY_QUERY_VALUE|KEY_SET_VALUE|WVR_OPENXR_REGISTRY_VIEW,NULL,&runtimeKey,NULL);
    if(result!=ERROR_SUCCESS)return fail("Open private-prefix OpenXR key",result);
    priorSize=0;result=RegQueryValueExW(runtimeKey,L"ActiveRuntime",NULL,&priorType,NULL,&priorSize);
    hadPrior=result==ERROR_SUCCESS;
    if(result!=ERROR_SUCCESS&&result!=ERROR_FILE_NOT_FOUND)return fail("Read prior ActiveRuntime",result);
    if(hadPrior){
        if(priorSize>65536)return fail("Prior ActiveRuntime too large",ERROR_INVALID_DATA);
        priorRuntime=(BYTE*)malloc(priorSize?priorSize:1);
        if(!priorRuntime)return fail("Allocate prior runtime value",ERROR_NOT_ENOUGH_MEMORY);
        result=RegQueryValueExW(runtimeKey,L"ActiveRuntime",NULL,&priorType,priorRuntime,&priorSize);
        if(result!=ERROR_SUCCESS)return fail("Read exact prior ActiveRuntime",result);
    }
    wcscpy(registeredPath,manifest);
    result=RegSetValueExW(runtimeKey,L"ActiveRuntime",0,REG_SZ,(const BYTE*)registeredPath,(DWORD)((wcslen(registeredPath)+1)*sizeof(wchar_t)));
    if(result!=ERROR_SUCCESS)return fail("Register private-prefix runtime",result);
    registeredRuntime=1;logline("registered validated private-prefix OpenXR runtime temporarily");return 0;
}

/* World vertices are transformed using the actual tracked HMD pose and raw
 * per-eye projection. The small fixed 64mm eye separation is approximate. */
typedef struct {float position[4],color[4];} Vertex;
static void vertex(Vertex *out,const TrackedDevicePose_t *head,int eye,const float *world,
                   const float *color,const float *frustum,int inverted) {
    float h[3]={world[0]-head->mDeviceToAbsoluteTracking.m[0][3],world[1]-head->mDeviceToAbsoluteTracking.m[1][3],world[2]-head->mDeviceToAbsoluteTracking.m[2][3]};
    float v[3]={0};
    for(int axis=0;axis<3;axis++)for(int row=0;row<3;row++)v[axis]+=head->mDeviceToAbsoluteTracking.m[row][axis]*h[row];
    v[0]-=eye==0?-.032f:.032f;
    float left=frustum[0],right=frustum[1],top=frustum[2],bottom=frustum[3];
    /* OpenVR raw top is negative and bottom positive. D3D clip Y points up. */
    out->position[0]=2*v[0]/(right-left)+(right+left)/(right-left)*v[2];
    out->position[1]=2*v[1]/(bottom-top)+(bottom+top)/(bottom-top)*v[2];
    if(inverted)out->position[1]=-out->position[1];
    out->position[2]=-(100.f/99.95f)*v[2]-(5.f/99.95f);
    out->position[3]=-v[2];
    memcpy(out->color,color,4*sizeof(float));
}
static VRTextureBounds_t makeBounds(int eye,int inverted) {
    return (VRTextureBounds_t){.uMin=inverted?eye*.5f:0,.uMax=inverted?(eye+1)*.5f:1,
                               .vMin=inverted?1:0,.vMax=inverted?0:1};
}
static const char shader[]=
    "struct V{float4 p:POSITION;float4 c:COLOR;};struct O{float4 p:SV_POSITION;float4 c:COLOR;};"
    "O vs(V v){O o;o.p=v.p;o.c=v.c;return o;}float4 ps(O v):SV_TARGET{return v.c;}";
#define CHECK(call) do{HRESULT result=(call);if(FAILED(result)){status=fail(#call,result);goto cleanup;}}while(0)
#define RELEASE(p) do{if(p){IUnknown_Release((IUnknown*)(p));(p)=NULL;}}while(0)

int WINAPI wWinMain(HINSTANCE instance,HINSTANCE previous,LPWSTR arguments,int show) {
    (void)previous;(void)show;
    int status=0,initialized=0,inverted=wcsstr(arguments,L"--inverted-bounds")!=NULL;
    HMODULE runtime=NULL;ShutdownFn shutdown=NULL;
    ID3D11Device *device=NULL;ID3D11DeviceContext *context=NULL;
    ID3D11Texture2D *textures[2]={NULL,NULL},*depth=NULL;
    ID3D11RenderTargetView *targets[2]={NULL,NULL};ID3D11DepthStencilView *depthView=NULL;
    ID3D11VertexShader *vs=NULL;ID3D11PixelShader *ps=NULL;ID3D11InputLayout *layout=NULL;
    ID3D11Buffer *vertices=NULL;ID3D11RasterizerState *raster=NULL;
    ID3DBlob *vsCode=NULL,*psCode=NULL,*errors=NULL;
    logfile=fopen("C:\\vr-smoke.log","w");
    logline("WineVision owned VR smoke v1; mode=%s; pointerBits=%u; approximate IPD=0.064m",inverted?"inverted-stereo":"two-textures",(unsigned)(8*sizeof(void*)));
    if(wcsstr(arguments,L"--cpu-self-test")){
        volatile uint32_t seed=0x12345678u;uint32_t value=seed;
        for(unsigned i=0;i<10000;i++)value=value*1664525u+1013904223u;
        HANDLE event=CreateEventW(NULL,FALSE,FALSE,NULL);
        if(!event){status=fail("CPU test CreateEvent",GetLastError());goto cleanup;}
        BOOL signaled=SetEvent(event);DWORD wait=WaitForSingleObject(event,1000);CloseHandle(event);
        if(value!=0xf0d18bc8u||!signaled||wait!=WAIT_OBJECT_0){status=fail("CPU test arithmetic/event",wait);goto cleanup;}
        logline("CPU SELF TEST PASS pointerBits=%u arithmetic=0x%08lx event=signaled",(unsigned)(8*sizeof(void*)),(unsigned long)value);goto cleanup;
    }
    wchar_t runtimePath[32768];DWORD length=GetEnvironmentVariableW(L"VR_OVERRIDE",runtimePath,32768);
    if(!length||length>=32700){status=fail("VR_OVERRIDE missing/too long",GetLastError());goto cleanup;}
    if(configureRuntime(runtimePath)){status=1;goto cleanup;}
    if(wcsstr(arguments,L"--registry-self-test")){logline("registry self-test configured; restoring without OpenXR execution");goto cleanup;}
    wcscat(runtimePath,WVR_OPENVR_DLL);
    runtime=LoadLibraryW(runtimePath);if(!runtime){status=fail("Load OpenComposite",GetLastError());goto cleanup;}
    InitFn init=(InitFn)(void*)GetProcAddress(runtime,"VR_InitInternal2");
    InterfaceFn getInterface=(InterfaceFn)(void*)GetProcAddress(runtime,"VR_GetGenericInterface");
    shutdown=(ShutdownFn)(void*)GetProcAddress(runtime,"VR_ShutdownInternal");
    if(!init||!getInterface||!shutdown){status=fail("OpenComposite exports missing",GetLastError());goto cleanup;}
    EVRInitError error=0;init(&error,EVRApplicationType_VRApplication_Scene,NULL);
    if(error){status=fail("VR_InitInternal2",error);goto cleanup;}initialized=1;
    System017 *system=(System017*)getInterface("FnTable:IVRSystem_017",&error);
    if(!system||error){status=fail("FnTable IVRSystem_017",error);goto cleanup;}
    Compositor021 *compositor=(Compositor021*)getInterface("FnTable:IVRCompositor_021",&error);
    if(!compositor||error){status=fail("FnTable IVRCompositor_021",error);goto cleanup;}
    compositor->setTrackingSpace(ETrackingUniverseOrigin_TrackingUniverseStanding);
    uint32_t width=0,height=0;system->recommended(&width,&height);
    logline("recommended=%ux%u; source=%ux%u",width,height,inverted?width*2:width,height);
    if(!width||!height||width>4096||height>4096){status=fail("Invalid recommended dimensions",0);goto cleanup;}
    float frustums[2][4];
    for(int eye=0;eye<2;eye++){
        system->projectionRaw((EVREye)eye,&frustums[eye][0],&frustums[eye][1],&frustums[eye][2],&frustums[eye][3]);
        logline("eye%d frustum=%f,%f,%f,%f",eye,frustums[eye][0],frustums[eye][1],frustums[eye][2],frustums[eye][3]);
        if(!isfinite(frustums[eye][0])||!isfinite(frustums[eye][1])||!isfinite(frustums[eye][2])||!isfinite(frustums[eye][3])||frustums[eye][1]<=frustums[eye][0]||frustums[eye][3]<=frustums[eye][2]){status=fail("Invalid projection frustum",eye);goto cleanup;}
    }
    CHECK(D3D11CreateDevice(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,0,NULL,0,D3D11_SDK_VERSION,&device,NULL,&context));
    D3D11_TEXTURE2D_DESC textureDesc={0};textureDesc.Width=inverted?width*2:width;textureDesc.Height=height;textureDesc.MipLevels=1;textureDesc.ArraySize=1;textureDesc.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;textureDesc.SampleDesc.Count=1;textureDesc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
    for(int eye=0;eye<(inverted?1:2);eye++){CHECK(ID3D11Device_CreateTexture2D(device,&textureDesc,NULL,&textures[eye]));CHECK(ID3D11Device_CreateRenderTargetView(device,(ID3D11Resource*)textures[eye],NULL,&targets[eye]));}
    textureDesc.Format=DXGI_FORMAT_D32_FLOAT;textureDesc.BindFlags=D3D11_BIND_DEPTH_STENCIL;
    CHECK(ID3D11Device_CreateTexture2D(device,&textureDesc,NULL,&depth));CHECK(ID3D11Device_CreateDepthStencilView(device,(ID3D11Resource*)depth,NULL,&depthView));
    CHECK(D3DCompile(shader,sizeof(shader)-1,NULL,NULL,NULL,"vs","vs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&vsCode,&errors));
    RELEASE(errors);
    CHECK(D3DCompile(shader,sizeof(shader)-1,NULL,NULL,NULL,"ps","ps_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&psCode,&errors));
    CHECK(ID3D11Device_CreateVertexShader(device,ID3D10Blob_GetBufferPointer(vsCode),ID3D10Blob_GetBufferSize(vsCode),NULL,&vs));
    CHECK(ID3D11Device_CreatePixelShader(device,ID3D10Blob_GetBufferPointer(psCode),ID3D10Blob_GetBufferSize(psCode),NULL,&ps));
    D3D11_INPUT_ELEMENT_DESC input[]={{"POSITION",0,DXGI_FORMAT_R32G32B32A32_FLOAT,0,0,D3D11_INPUT_PER_VERTEX_DATA,0},{"COLOR",0,DXGI_FORMAT_R32G32B32A32_FLOAT,0,16,D3D11_INPUT_PER_VERTEX_DATA,0}};
    CHECK(ID3D11Device_CreateInputLayout(device,input,2,ID3D10Blob_GetBufferPointer(vsCode),ID3D10Blob_GetBufferSize(vsCode),&layout));
    D3D11_BUFFER_DESC buffer={0};buffer.ByteWidth=42*sizeof(Vertex);buffer.Usage=D3D11_USAGE_DYNAMIC;buffer.BindFlags=D3D11_BIND_VERTEX_BUFFER;buffer.CPUAccessFlags=D3D11_CPU_ACCESS_WRITE;
    CHECK(ID3D11Device_CreateBuffer(device,&buffer,NULL,&vertices));
    D3D11_RASTERIZER_DESC rasterDesc={0};rasterDesc.FillMode=D3D11_FILL_SOLID;rasterDesc.CullMode=D3D11_CULL_NONE;rasterDesc.DepthClipEnable=TRUE;
    CHECK(ID3D11Device_CreateRasterizerState(device,&rasterDesc,&raster));
    ID3D11DeviceContext_RSSetState(context,raster);ID3D11DeviceContext_IASetInputLayout(context,layout);ID3D11DeviceContext_IASetPrimitiveTopology(context,D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(context,vs,NULL,0);ID3D11DeviceContext_PSSetShader(context,ps,NULL,0);
    UINT stride=sizeof(Vertex),offset=0;ID3D11DeviceContext_IASetVertexBuffers(context,0,1,&vertices,&stride,&offset);
    WNDCLASSW klass={0};klass.lpfnWndProc=windowProc;klass.hInstance=instance;klass.lpszClassName=L"WineVisionVRSmoke";RegisterClassW(&klass);
    HWND window=CreateWindowW(klass.lpszClassName,L"WineVision VR test - Escape to close",WS_OVERLAPPEDWINDOW,0,0,480,240,NULL,NULL,instance,NULL);
    if(!window){status=fail("CreateWindow",GetLastError());goto cleanup;}
    ShowWindow(window,SW_SHOW);
    static const float cube[8][3]={{-.3f,1.1f,-2.3f},{.3f,1.1f,-2.3f},{.3f,1.7f,-2.3f},{-.3f,1.7f,-2.3f},{-.3f,1.1f,-1.7f},{.3f,1.1f,-1.7f},{.3f,1.7f,-1.7f},{-.3f,1.7f,-1.7f}};
    static const unsigned indices[36]={0,1,2,0,2,3,4,6,5,4,7,6,0,4,5,0,5,1,3,2,6,3,6,7,0,3,7,0,7,4,1,5,6,1,6,2};
    static const float colors[6][4]={{1,.2f,.1f,1},{.1f,.8f,1,1},{1,.8f,.1f,1},{.3f,1,.3f,1},{.8f,.2f,1,1},{1,.5f,.1f,1}};
    static const float floorPoints[6][3]={{-4,0,-6},{4,0,-6},{4,0,1},{-4,0,-6},{4,0,1},{-4,0,1}},floorColor[4]={.12f,.22f,.18f,1};
    uint64_t frames=0;unsigned untracked=0;
    while(running){
        MSG message;while(PeekMessageW(&message,NULL,0,0,PM_REMOVE)){if(message.message==WM_QUIT)running=0;TranslateMessage(&message);DispatchMessageW(&message);}if(!running)break;
        TrackedDevicePose_t poses[64]={0};EVRCompositorError result=compositor->waitPoses(poses,64,NULL,0);
        if(result){status=fail("WaitGetPoses",result);break;}
        if(!poses[0].bPoseIsValid){if(++untracked<=4)logline("head pose unavailable; waiting");Sleep(5);continue;}
        if(inverted)ID3D11DeviceContext_ClearDepthStencilView(context,depthView,D3D11_CLEAR_DEPTH,1,0);
        for(int eye=0;eye<2;eye++){
            if(!inverted)ID3D11DeviceContext_ClearDepthStencilView(context,depthView,D3D11_CLEAR_DEPTH,1,0);
            const int target=inverted?0:eye;float background[4]={eye==0?.025f:.045f,.035f,eye==0?.065f:.025f,1};
            if(!inverted||eye==0)ID3D11DeviceContext_ClearRenderTargetView(context,targets[target],background);
            D3D11_VIEWPORT viewport={(float)(inverted?eye*width:0),0,(float)width,(float)height,0,1};ID3D11DeviceContext_RSSetViewports(context,1,&viewport);ID3D11DeviceContext_OMSetRenderTargets(context,1,&targets[target],depthView);
            D3D11_MAPPED_SUBRESOURCE mapped;CHECK(ID3D11DeviceContext_Map(context,(ID3D11Resource*)vertices,0,D3D11_MAP_WRITE_DISCARD,0,&mapped));Vertex *v=(Vertex*)mapped.pData;
            for(int n=0;n<36;n++)vertex(&v[n],&poses[0],eye,cube[indices[n]],colors[n/6],frustums[eye],inverted);
            for(int n=0;n<6;n++)vertex(&v[n+36],&poses[0],eye,floorPoints[n],floorColor,frustums[eye],inverted);
            ID3D11DeviceContext_Unmap(context,(ID3D11Resource*)vertices,0);ID3D11DeviceContext_Draw(context,42,0);
        }
        for(int eye=0;eye<2;eye++){
            Texture_t texture={textures[inverted?0:eye],ETextureType_TextureType_DirectX,EColorSpace_ColorSpace_Gamma};
            VRTextureBounds_t bounds=makeBounds(eye,inverted);
            result=compositor->submit((EVREye)eye,&texture,&bounds,EVRSubmitFlags_Submit_Default);
            if(result){status=fail(eye?"Submit right":"Submit left",result);goto cleanup;}
        }
        frames++;if(frames<=4||frames%300==0)logline("submitted frame=%llu head=%.3f,%.3f,%.3f",(unsigned long long)frames,poses[0].mDeviceToAbsoluteTracking.m[0][3],poses[0].mDeviceToAbsoluteTracking.m[1][3],poses[0].mDeviceToAbsoluteTracking.m[2][3]);
    }
cleanup:
    logline("exit status=%d",status);
    if(context)ID3D11DeviceContext_ClearState(context);
    RELEASE(errors);RELEASE(vsCode);RELEASE(psCode);RELEASE(raster);RELEASE(vertices);RELEASE(layout);RELEASE(vs);RELEASE(ps);RELEASE(depthView);RELEASE(depth);
    for(int i=0;i<2;i++){RELEASE(targets[i]);RELEASE(textures[i]);}RELEASE(context);RELEASE(device);
    if(initialized&&shutdown)shutdown();if(runtime)FreeLibrary(runtime);restoreRuntimeRegistration();if(logfile)fclose(logfile);
    return status;
}
