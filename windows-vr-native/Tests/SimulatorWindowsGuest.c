// Minimal x64 Windows executable: exercises FEX -> Wine imports -> clean exit.
#include <windows.h>
void entry(void) {
    static const char marker[] = "x64 Windows guest entry reached\n";
    HANDLE file = CreateFileA("C:\\wvr-simulator-guest-ok.txt", GENERIC_WRITE,
                             0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) ExitProcess(10);
    DWORD written = 0;
    BOOL success = WriteFile(file, marker, sizeof(marker)-1, &written, NULL);
    CloseHandle(file);
    if (!success || written != sizeof(marker)-1) ExitProcess(11);
    OutputDebugStringA("[WVR Simulator] x64 guest entry reached\n");
    ExitProcess(0);
}
