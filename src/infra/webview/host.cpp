#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <objbase.h>
#if defined(__MINGW32__) && defined(__clang__)
// Preserve UUID attributes that MinGW otherwise erases from WebView2 interfaces.
#ifdef __uuidof
#undef __uuidof
#endif
#undef MIDL_INTERFACE
#define MIDL_INTERFACE(iid) struct __declspec(uuid(iid))
struct __declspec(uuid("00000000-0000-0000-C000-000000000046")) IUnknown;
#endif
// MinGW lacks EventToken.h; alias its import without modifying vendor headers.
#if defined(__MINGW32__) && !__has_include("EventToken.h")
typedef struct EventRegistrationToken { INT64 value; } EventRegistrationToken;
#pragma include_alias("EventToken.h", "windows.h")
#endif
#include <WebView2.h>
#include <stddef.h>
#include <string.h>
#include <wchar.h>
#include <new>

extern "C" char* kasirku_dispatch(const char* request);
extern "C" void kasirku_free(char* response);

namespace {
constexpr wchar_t kUrl[] = L"https://kasirku.local/index.html";
constexpr wchar_t kClass[] = L"KasirKu.Offline.Host";
constexpr size_t kMessageLimit = 64 * 1024;
constexpr unsigned kQueueLimit = 64;
constexpr DWORD kPathLimit = 32768;
constexpr UINT kResultsMessage = WM_APP + 41;
constexpr UINT_PTR kSmokeTimer = 41;
constexpr wchar_t kRuntimeError[] =
    L"Microsoft Edge WebView2 Runtime tidak ditemukan atau tidak dapat digunakan. "
    L"Pasang WebView2 Runtime Evergreen (x64) secara offline, lalu buka kembali KasirKu.";

HRESULT LastErrorHr() {
    const DWORD error = GetLastError();
    return HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
}
void LogHr(const wchar_t* message, HRESULT hr) {
    wchar_t text[768];
    _snwprintf(text, sizeof(text) / sizeof(text[0]), L"KasirKu: %ls (0x%08lX)\n",
               message, static_cast<unsigned long>(hr));
    text[sizeof(text) / sizeof(text[0]) - 1] = 0;
    OutputDebugStringW(text);
}
void CleanupHr(HRESULT hr) {
    if (FAILED(hr)) LogHr(L"Pembersihan WebView2", hr);
}

struct HeapObject {
    static void* operator new(size_t size) noexcept {
        return HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, size);
    }
    static void operator delete(void* value) noexcept {
        if (value) HeapFree(GetProcessHeap(), 0, value);
    }
};
template<class T> struct HeapBuffer {
    T* value = nullptr;
    HeapBuffer() = default;
    explicit HeapBuffer(size_t count)
        : value(static_cast<T*>(HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, count * sizeof(T)))) {}
    ~HeapBuffer() { if (value) HeapFree(GetProcessHeap(), 0, value); }
    HeapBuffer(const HeapBuffer&) = delete;
    HeapBuffer& operator=(const HeapBuffer&) = delete;
};
template<class T> struct ComPtr {
    T* value = nullptr;
    ComPtr() = default;
    explicit ComPtr(T* p) : value(p) {}
    ~ComPtr() { reset(); }
    void reset() { if (value) { T* p = value; value = nullptr; p->Release(); } }
    T** out() { reset(); return &value; }
    T* operator->() const { return value; }
    ComPtr(const ComPtr&) = delete;
    ComPtr& operator=(const ComPtr&) = delete;
};
struct ComText {
    wchar_t* value = nullptr;
    ~ComText() { CoTaskMemFree(value); }
};
struct Handle {
    HANDLE value = nullptr;
    ~Handle() { if (value) CloseHandle(value); }
};
struct Apartment {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ~Apartment() { if (SUCCEEDED(hr)) CoUninitialize(); }
};
struct DpiScope {
    // Thread awareness works even when the caller already set process awareness.
    using SetContext = HANDLE (WINAPI*)(HANDLE);
    SetContext set = reinterpret_cast<SetContext>(
        GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetThreadDpiAwarenessContext"));
    HANDLE previous = set ? set(reinterpret_cast<HANDLE>(static_cast<INT_PTR>(-4))) : nullptr;
    ~DpiScope() { if (previous) set(previous); }
};

// Envelope parsing prevents nested or escaped fields from falsely passing the smoke test.
struct Slice { const char* begin = nullptr; const char* end = nullptr; };
bool Equals(Slice value, const char* expected) {
    return value.begin && static_cast<size_t>(value.end - value.begin) == strlen(expected) &&
           memcmp(value.begin, expected, strlen(expected)) == 0;
}
int Hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
bool StringEquals(Slice value, const char* expected) {
    if (!value.begin || *value.begin != '"') return false;
    const char* p = value.begin + 1;
    const char* end = value.end - 1;
    while (p < end) {
        unsigned c = static_cast<unsigned char>(*p++);
        if (c == '\\') {
            c = static_cast<unsigned char>(*p++);
            if (c == 'u') {
                c = 0;
                for (int i = 0; i < 4; ++i) c = c * 16 + static_cast<unsigned>(Hex(*p++));
            } else {
                switch (c) {
                    case 'b': c = '\b'; break; case 'f': c = '\f'; break;
                    case 'n': c = '\n'; break; case 'r': c = '\r'; break;
                    case 't': c = '\t'; break; default: break;
                }
            }
        }
        if (!*expected || c != static_cast<unsigned char>(*expected++)) return false;
    }
    return *expected == 0;
}
struct Envelope {
    Slice id;
    bool ok = false;
    bool okBoolean = false;
    bool pong = false;
    bool ping = false;
    bool smokeAck = false;
    unsigned seen = 0;
};
class Json {
    const char* p;
    const char* end;
    void space() { while (p < end && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t')) ++p; }
    bool take(char c) { space(); if (p < end && *p == c) { ++p; return true; } return false; }
    bool string(Slice& slice) {
        space();
        if (p == end || *p != '"') return false;
        slice.begin = p++;
        while (p < end) {
            unsigned char c = static_cast<unsigned char>(*p++);
            if (c == '"') { slice.end = p; return true; }
            if (c < 32) return false;
            if (c != '\\') continue;
            if (p == end) return false;
            char escaped = *p++;
            if (escaped == 'u') {
                for (int i = 0; i < 4; ++i) if (p == end || Hex(*p++) < 0) return false;
            } else if (escaped != '"' && escaped != '\\' && escaped != '/' &&
                       escaped != 'b' && escaped != 'f' && escaped != 'n' &&
                       escaped != 'r' && escaped != 't') return false;
        }
        return false;
    }
    bool literal(const char* text) {
        size_t n = strlen(text);
        if (static_cast<size_t>(end - p) < n || memcmp(p, text, n)) return false;
        p += n;
        return true;
    }
    bool number() {
        if (p < end && *p == '-') ++p;
        if (p == end) return false;
        if (*p == '0') ++p;
        else {
            if (*p < '1' || *p > '9') return false;
            do { ++p; } while (p < end && *p >= '0' && *p <= '9');
        }
        if (p < end && *p == '.') {
            ++p;
            if (p == end || *p < '0' || *p > '9') return false;
            do { ++p; } while (p < end && *p >= '0' && *p <= '9');
        }
        if (p < end && (*p == 'e' || *p == 'E')) {
            ++p;
            if (p < end && (*p == '+' || *p == '-')) ++p;
            if (p == end || *p < '0' || *p > '9') return false;
            do { ++p; } while (p < end && *p >= '0' && *p <= '9');
        }
        return true;
    }
    bool value(unsigned depth, Envelope* envelope = nullptr, bool result = false) {
        space();
        if (depth > 64 || p == end) return false;
        if (*p == '{') {
            ++p;
            if (take('}')) return true;
            do {
                Slice key;
                if (!string(key) || !take(':')) return false;
                space();
                const char* start = p;
                unsigned field = 0;
                if (envelope) {
                    if (result) { if (StringEquals(key, "pong")) field = 16; }
                    else if (StringEquals(key, "id")) field = 1;
                    else if (StringEquals(key, "ok")) field = 2;
                    else if (StringEquals(key, "result")) field = 4;
                    else if (StringEquals(key, "command")) field = 8;
                    if (field && (envelope->seen & field)) return false;
                    envelope->seen |= field;
                }
                if (!value(depth + 1, field == 4 ? envelope : nullptr, field == 4)) return false;
                Slice content{start, p};
                if (field == 1 && (*start == '"' || Equals(content, "null"))) envelope->id = content;
                if (field == 2) {
                    envelope->ok = Equals(content, "true");
                    envelope->okBoolean = envelope->ok || Equals(content, "false");
                }
                if (field == 8) {
                    envelope->ping = StringEquals(content, "system.ping");
                    envelope->smokeAck = StringEquals(content, "native.smoke.ack");
                }
                if (field == 16) envelope->pong = Equals(content, "true");
            } while (take(','));
            return take('}');
        }
        if (*p == '[') {
            ++p;
            if (take(']')) return true;
            do { if (!value(depth + 1)) return false; } while (take(','));
            return take(']');
        }
        if (*p == '"') { Slice ignored; return string(ignored); }
        if (*p == 't') return literal("true");
        if (*p == 'f') return literal("false");
        if (*p == 'n') return literal("null");
        return number();
    }
public:
    Json(const char* text, size_t length) : p(text), end(text + length) {}
    bool inspect(Envelope& envelope) {
        space();
        if (p == end || *p != '{' || !value(0, &envelope)) return false;
        space();
        return p == end;
    }
};
size_t BoundedLength(const char* text) {
    size_t length = 0;
    if (text) while (length <= kMessageLimit && text[length]) ++length;
    return length;
}

class Host;
struct Context : HeapObject {
    LONG references = 1;
    Host* host = nullptr; // Read/write only in the owning STA, never by the DB worker.
    HMODULE loader = nullptr;
    void addRef() { InterlockedIncrement(&references); }
    void release() { if (!InterlockedDecrement(&references)) delete this; }
    ~Context() { if (loader) FreeLibrary(loader); }
};
template<class Derived, class Interface> class RefCount : public Interface, public HeapObject {
    LONG references = 1;
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (!IsEqualIID(iid, __uuidof(IUnknown)) && !IsEqualIID(iid, __uuidof(Interface))) return E_NOINTERFACE;
        *out = static_cast<Interface*>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&references)); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG count = static_cast<ULONG>(InterlockedDecrement(&references));
        if (!count) delete static_cast<Derived*>(this);
        return count;
    }
};
template<class Interface, class A, class B>
class Callback final : public RefCount<Callback<Interface, A, B>, Interface> {
    Context* context;
    HRESULT (*function)(Context*, A, B);
public:
    Callback(Context* c, HRESULT (*f)(Context*, A, B)) : context(c), function(f) { context->addRef(); }
    ~Callback() { context->release(); }
    HRESULT STDMETHODCALLTYPE Invoke(A a, B b) override { return function(context, a, b); }
};
struct Registration { EventRegistrationToken token{}; bool active = false; };
template<class Interface, class Source, class A, class B>
HRESULT Subscribe(Context* context, Source* source,
                  HRESULT (STDMETHODCALLTYPE Source::*add)(Interface*, EventRegistrationToken*),
                  HRESULT (*function)(Context*, A, B), Registration& registration) {
    ComPtr<Interface> callback(new Callback<Interface, A, B>(context, function));
    if (!callback.value) return E_OUTOFMEMORY;
    HRESULT hr = (source->*add)(callback.value, &registration.token);
    registration.active = SUCCEEDED(hr);
    return hr;
}
template<class Source>
void Unsubscribe(Source* source, HRESULT (STDMETHODCALLTYPE Source::*remove)(EventRegistrationToken),
                 Registration& registration) {
    if (source && registration.active) CleanupHr((source->*remove)(registration.token));
    registration.active = false;
}

struct Work : HeapObject {
    char* response = nullptr; // Zig-owned, freed exactly once after posting or discarding.
    size_t length = 0;
    UINT64 generation = 0;
    bool smoke = false;
    char* request() { return reinterpret_cast<char*>(this + 1); }
    static Work* create(size_t bytes) {
        // Heap storage includes the terminated request; placement new starts Work's lifetime.
        void* memory = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(Work) + bytes + 1);
        return memory ? ::new (memory) Work : nullptr;
    }
    ~Work() { if (response) kasirku_free(response); }
};

#define RETURN_IF_FAILED(expression) do { HRESULT result_ = (expression); if (FAILED(result_)) return result_; } while (0)

class Host : public HeapObject {
public:
    explicit Host(bool smoke) : smoke_(smoke), exitCode_(smoke ? 1 : 0) {}
    ~Host();
    int run(const wchar_t* dataDir);
    static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
private:
    bool smoke_;
    int exitCode_;
    bool closing_ = false;
    bool detached_ = false;
    bool lockInitialized_ = false;
    bool classRegistered_ = false;
    bool trustedNavigation_ = false;
    bool smokeSent_ = false;
    bool smokeQueued_ = false;
    bool smokeResponsePosted_ = false;
    UINT64 navigationId_ = 0;
    UINT64 generation_ = 0;
    ULONGLONG smokeDeadline_ = 0;
    UINT dpi_ = 96;
    HWND window_ = nullptr;
    HWND workerWindow_ = nullptr; // Immutable until the worker has joined.
    Context* context_ = nullptr;
    ComPtr<ICoreWebView2Environment> environment_;
    ComPtr<ICoreWebView2Controller> controller_;
    ComPtr<ICoreWebView2> webview_;
    ComPtr<ICoreWebView2_4> webview4_;
    ComPtr<ICoreWebView2Controller4> controller4_;
    HeapBuffer<wchar_t> uiPath_{kPathLimit};
    HeapBuffer<wchar_t> profilePath_{kPathLimit};
    Registration navigation_, frames_, completed_, messages_, permissions_, windows_, downloads_, processes_, sources_;
    const wchar_t* error_ = nullptr;
    HRESULT errorHr_ = S_OK;
    CRITICAL_SECTION lock_{};
    Handle workReady_;
    Handle resultsReady_;
    Handle worker_;
    Work* pending_[kQueueLimit]{};
    Work* finished_[kQueueLimit]{};
    unsigned pendingHead_ = 0, pendingCount_ = 0;
    unsigned finishedHead_ = 0, finishedCount_ = 0;
    unsigned outstanding_ = 0;
    bool workerStopping_ = false; // Protected by lock_; all other worker access is queue/handles only.
    DWORD workerError_ = ERROR_SUCCESS;

    void fail(const wchar_t* message, HRESULT hr);
    void close(int code);
    void detach();
    HRESULT prepare(const wchar_t* dataDir);
    HRESULT configure();
    HRESULT resize();
    HRESULT postJson(const char* json, size_t length);
    void reject(const char* code, const char* request = nullptr, size_t length = 0);
    bool sourceTrusted();
    void drainResults();
    static DWORD WINAPI WorkerProc(void* self);
    DWORD work();
    HRESULT environmentCreated(HRESULT hr, ICoreWebView2Environment* environment);
    HRESULT controllerCreated(HRESULT hr, ICoreWebView2Controller* controller);
    HRESULT navigationStarting(ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args);
    HRESULT navigationCompleted(ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs* args);
    HRESULT messageReceived(ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args);

    static HRESULT Environment(Context* c, HRESULT hr, ICoreWebView2Environment* e) {
        return c->host ? c->host->environmentCreated(hr, e) : S_OK;
    }
    static HRESULT Controller(Context* c, HRESULT hr, ICoreWebView2Controller* controller) {
        if (c->host && !c->host->closing_) return c->host->controllerCreated(hr, controller);
        if (controller) CleanupHr(controller->Close());
        return S_OK;
    }
    static HRESULT Navigation(Context* c, ICoreWebView2* sender, ICoreWebView2NavigationStartingEventArgs* a) {
        if (c->host) return c->host->navigationStarting(sender, a);
        return a ? a->put_Cancel(TRUE) : E_POINTER;
    }
    static HRESULT Frame(Context* c, ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* a) {
        HRESULT hr = a ? a->put_Cancel(TRUE) : E_POINTER;
        if (FAILED(hr) && c->host) c->host->fail(L"Tidak dapat memblokir bingkai halaman.", hr);
        return hr;
    }
    static HRESULT Completed(Context* c, ICoreWebView2* sender, ICoreWebView2NavigationCompletedEventArgs* a) {
        return c->host ? c->host->navigationCompleted(sender, a) : S_OK;
    }
    static HRESULT Message(Context* c, ICoreWebView2* sender, ICoreWebView2WebMessageReceivedEventArgs* a) {
        return c->host ? c->host->messageReceived(sender, a) : S_OK;
    }
    static HRESULT Permission(Context* c, ICoreWebView2*, ICoreWebView2PermissionRequestedEventArgs* a) {
        HRESULT hr = a ? a->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY) : E_POINTER;
        if (FAILED(hr) && c->host) c->host->fail(L"Tidak dapat menolak izin halaman.", hr);
        return hr;
    }
    static HRESULT NewWindow(Context* c, ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* a) {
        HRESULT hr = a ? a->put_Handled(TRUE) : E_POINTER;
        if (FAILED(hr) && c->host) c->host->fail(L"Tidak dapat memblokir jendela baru.", hr);
        return hr;
    }
    static HRESULT Download(Context* c, ICoreWebView2*, ICoreWebView2DownloadStartingEventArgs* a) {
        HRESULT hr = a ? a->put_Cancel(TRUE) : E_POINTER;
        HRESULT handled = a ? a->put_Handled(TRUE) : E_POINTER;
        if (SUCCEEDED(hr)) hr = handled;
        if (FAILED(hr) && c->host) c->host->fail(L"Tidak dapat memblokir unduhan.", hr);
        return hr;
    }
    static HRESULT ProcessFailed(Context* c, ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs*) {
        if (c->host) c->host->fail(L"Proses WebView2 berhenti. Tutup dan buka kembali KasirKu.", E_FAIL);
        return S_OK;
    }
    static HRESULT SourceChanged(Context* c, ICoreWebView2*, ICoreWebView2SourceChangedEventArgs*) {
        if (c->host && c->host->trustedNavigation_ && !c->host->closing_ && !c->host->sourceTrusted())
            c->host->fail(L"Alamat halaman di luar aplikasi diblokir.", E_ACCESSDENIED);
        return S_OK;
    }
    static HRESULT ScriptExecuted(Context* c, HRESULT hr, LPCWSTR result) {
        if (c->host && !c->host->closing_ && (FAILED(hr) || !result || wcscmp(result, L"true")))
            c->host->fail(L"Uji komunikasi halaman tidak dapat dijalankan.", FAILED(hr) ? hr : E_FAIL);
        return S_OK;
    }
};

void Host::fail(const wchar_t* message, HRESULT hr) {
    if (!error_) { error_ = message; errorHr_ = hr; LogHr(message, hr); }
    close(1);
}
void Host::close(int code) {
    if (code) exitCode_ = code;
    else if (!closing_) exitCode_ = 0;
    if (closing_) return;
    closing_ = true;
    trustedNavigation_ = false;
    if (window_ && smoke_) KillTimer(window_, kSmokeTimer);
    if (lockInitialized_) {
        EnterCriticalSection(&lock_);
        workerStopping_ = true;
        if (workReady_.value && !SetEvent(workReady_.value)) workerError_ = GetLastError();
        LeaveCriticalSection(&lock_);
    }
    // COM teardown must run outside WebView event callbacks.
}

HRESULT JoinPath(wchar_t* output, const wchar_t* directory, const wchar_t* leaf) {
    const size_t length = wcslen(directory), extra = wcslen(leaf);
    bool separator = length && directory[length - 1] != L'\\' && directory[length - 1] != L'/';
    if (!length || length + (separator ? 1 : 0) + extra >= kPathLimit) return HRESULT_FROM_WIN32(ERROR_FILENAME_EXCED_RANGE);
    memmove(output, directory, length * sizeof(wchar_t));
    size_t at = length;
    if (separator) output[at++] = L'\\';
    memcpy(output + at, leaf, (extra + 1) * sizeof(wchar_t));
    return S_OK;
}
HRESULT Host::prepare(const wchar_t* dataDir) {
    if (!dataDir || !*dataDir) return E_INVALIDARG;
    if (!uiPath_.value || !profilePath_.value) return E_OUTOFMEMORY;
    HeapBuffer<wchar_t> executable(kPathLimit), path(kPathLimit);
    if (!executable.value || !path.value) return E_OUTOFMEMORY;
    DWORD length = GetModuleFileNameW(nullptr, executable.value, kPathLimit);
    if (!length) return LastErrorHr();
    if (length >= kPathLimit) return HRESULT_FROM_WIN32(ERROR_FILENAME_EXCED_RANGE);
    wchar_t* slash = wcsrchr(executable.value, L'\\');
    if (!slash) return E_INVALIDARG;
    *slash = 0;
    RETURN_IF_FAILED(JoinPath(uiPath_.value, executable.value, L"ui"));
    RETURN_IF_FAILED(JoinPath(path.value, uiPath_.value, L"index.html"));
    DWORD attributes = GetFileAttributesW(path.value);
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        fail(L"Berkas UI tidak ditemukan. Pastikan folder ui/index.html berada di samping aplikasi.", HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND));
        return HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
    }
    length = GetFullPathNameW(dataDir, kPathLimit, path.value, nullptr);
    if (!length) return LastErrorHr();
    if (length >= kPathLimit) return HRESULT_FROM_WIN32(ERROR_FILENAME_EXCED_RANGE);
    RETURN_IF_FAILED(JoinPath(profilePath_.value, path.value, L"webview"));
    if (!CreateDirectoryW(profilePath_.value, nullptr)) {
        DWORD error = GetLastError();
        attributes = GetFileAttributesW(profilePath_.value);
        if (error != ERROR_ALREADY_EXISTS || attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY))
            return HRESULT_FROM_WIN32(error);
    }
    context_ = new Context;
    if (!context_) return E_OUTOFMEMORY;
    context_->host = this;
    RETURN_IF_FAILED(JoinPath(path.value, executable.value, L"WebView2Loader.dll"));
    context_->loader = LoadLibraryExW(path.value, nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!context_->loader) {
        HRESULT hr = LastErrorHr();
        fail(L"WebView2Loader.dll (x64) tidak dapat dimuat. Letakkan DLL asli di samping aplikasi.", hr);
        return hr;
    }
    using Version = HRESULT (STDAPICALLTYPE*)(PCWSTR, LPWSTR*);
    Version version = reinterpret_cast<Version>(GetProcAddress(context_->loader, "GetAvailableCoreWebView2BrowserVersionString"));
    if (!version) return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    ComText installed;
    HRESULT hr = version(nullptr, &installed.value);
    if (FAILED(hr) || !installed.value || !*installed.value) {
        hr = FAILED(hr) ? hr : HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
        fail(kRuntimeError, hr);
        return hr;
    }
    if (!InitializeCriticalSectionEx(&lock_, 0, 0)) return LastErrorHr();
    lockInitialized_ = true;
    workReady_.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!workReady_.value) return LastErrorHr();
    resultsReady_.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!resultsReady_.value) return LastErrorHr();
    return S_OK;
}

HRESULT Host::environmentCreated(HRESULT hr, ICoreWebView2Environment* environment) {
    if (closing_) return S_OK;
    if (FAILED(hr) || !environment) { fail(kRuntimeError, FAILED(hr) ? hr : E_POINTER); return S_OK; }
    environment->AddRef();
    environment_.value = environment;
    ComPtr<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler> callback(
        new Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, HRESULT, ICoreWebView2Controller*>(context_, Controller));
    hr = callback.value ? environment_->CreateCoreWebView2Controller(window_, callback.value) : E_OUTOFMEMORY;
    if (FAILED(hr)) fail(L"Jendela WebView2 tidak dapat dibuat.", hr);
    return S_OK;
}
HRESULT Host::controllerCreated(HRESULT hr, ICoreWebView2Controller* controller) {
    if (FAILED(hr) || !controller) { fail(L"WebView2 tidak dapat diinisialisasi.", FAILED(hr) ? hr : E_POINTER); return S_OK; }
    controller->AddRef();
    controller_.value = controller;
    hr = configure();
    if (FAILED(hr)) fail(L"Pengamanan WebView2 tidak dapat diaktifkan. Perbarui WebView2 Runtime secara offline.", hr);
    return S_OK;
}
HRESULT Host::configure() {
    RETURN_IF_FAILED(controller_->get_CoreWebView2(webview_.out()));
    if (!webview_.value) return E_POINTER;
    RETURN_IF_FAILED(webview_->QueryInterface(__uuidof(ICoreWebView2_4), reinterpret_cast<void**>(webview4_.out())));
    RETURN_IF_FAILED(controller_->QueryInterface(__uuidof(ICoreWebView2Controller4), reinterpret_cast<void**>(controller4_.out())));
    RETURN_IF_FAILED(controller4_->put_AllowExternalDrop(FALSE));
    RETURN_IF_FAILED(controller4_->put_BoundsMode(COREWEBVIEW2_BOUNDS_MODE_USE_RAW_PIXELS));
    RETURN_IF_FAILED(controller4_->put_ShouldDetectMonitorScaleChanges(TRUE));
    ComPtr<ICoreWebView2Settings> settings;
    ComPtr<ICoreWebView2Settings3> settings3;
    RETURN_IF_FAILED(webview_->get_Settings(settings.out()));
    if (!settings.value) return E_POINTER;
    RETURN_IF_FAILED(settings->QueryInterface(__uuidof(ICoreWebView2Settings3), reinterpret_cast<void**>(settings3.out())));
    RETURN_IF_FAILED(settings->put_IsScriptEnabled(TRUE));
    RETURN_IF_FAILED(settings->put_IsWebMessageEnabled(TRUE));
    RETURN_IF_FAILED(settings->put_AreHostObjectsAllowed(FALSE));
    RETURN_IF_FAILED(settings->put_AreDevToolsEnabled(FALSE));
    RETURN_IF_FAILED(settings->put_AreDefaultContextMenusEnabled(FALSE));
    RETURN_IF_FAILED(settings->put_AreDefaultScriptDialogsEnabled(FALSE));
    RETURN_IF_FAILED(settings->put_IsStatusBarEnabled(FALSE));
    RETURN_IF_FAILED(settings->put_IsZoomControlEnabled(FALSE));
    RETURN_IF_FAILED(settings->put_IsBuiltInErrorPageEnabled(FALSE));
    RETURN_IF_FAILED(settings3->put_AreBrowserAcceleratorKeysEnabled(FALSE));
    ComPtr<ICoreWebView2_3> mapping;
    RETURN_IF_FAILED(webview_->QueryInterface(__uuidof(ICoreWebView2_3), reinterpret_cast<void**>(mapping.out())));
    RETURN_IF_FAILED(mapping->SetVirtualHostNameToFolderMapping(L"kasirku.local", uiPath_.value,
        COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS));
    RETURN_IF_FAILED(Subscribe(context_, webview_.value, &ICoreWebView2::add_NavigationStarting, Navigation, navigation_));
    RETURN_IF_FAILED(Subscribe(context_, webview_.value, &ICoreWebView2::add_FrameNavigationStarting, Frame, frames_));
    RETURN_IF_FAILED(Subscribe(context_, webview_.value, &ICoreWebView2::add_NavigationCompleted, Completed, completed_));
    // This is the TOP-LEVEL WebMessageReceived event. Never register a frame's bridge event.
    RETURN_IF_FAILED(Subscribe(context_, webview_.value, &ICoreWebView2::add_WebMessageReceived, Message, messages_));
    RETURN_IF_FAILED(Subscribe(context_, webview_.value, &ICoreWebView2::add_PermissionRequested, Permission, permissions_));
    RETURN_IF_FAILED(Subscribe(context_, webview_.value, &ICoreWebView2::add_NewWindowRequested, NewWindow, windows_));
    RETURN_IF_FAILED(Subscribe(context_, webview4_.value, &ICoreWebView2_4::add_DownloadStarting, Download, downloads_));
    RETURN_IF_FAILED(Subscribe(context_, webview_.value, &ICoreWebView2::add_ProcessFailed, ProcessFailed, processes_));
    RETURN_IF_FAILED(Subscribe(context_, webview_.value, &ICoreWebView2::add_SourceChanged, SourceChanged, sources_));
    RETURN_IF_FAILED(resize());
    RETURN_IF_FAILED(controller_->put_IsVisible(TRUE));
    RETURN_IF_FAILED(webview_->Navigate(kUrl));
    return S_OK;
}
HRESULT Host::resize() {
    if (!controller_.value || closing_) return S_OK;
    RECT bounds{};
    if (!GetClientRect(window_, &bounds)) return LastErrorHr();
    RETURN_IF_FAILED(controller_->put_Bounds(bounds));
    RETURN_IF_FAILED(controller_->NotifyParentWindowPositionChanged());
    return S_OK;
}
bool Host::sourceTrusted() {
    if (!webview_.value || !trustedNavigation_ || closing_) return false;
    ComText source;
    HRESULT hr = webview_->get_Source(&source.value);
    if (FAILED(hr)) { fail(L"Alamat halaman tidak dapat diverifikasi.", hr); return false; }
    return source.value && wcscmp(source.value, kUrl) == 0;
}
HRESULT Host::navigationStarting(ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) {
    if (!args) { fail(L"Navigasi tidak dapat diverifikasi.", E_POINTER); return E_POINTER; }
    ComText uri;
    HRESULT hr = args->get_Uri(&uri.value);
    bool allow = SUCCEEDED(hr) && uri.value && wcscmp(uri.value, kUrl) == 0 && !closing_;
    if (!allow) {
        HRESULT cancel = args->put_Cancel(TRUE);
        if (FAILED(cancel)) fail(L"Navigasi di luar aplikasi tidak dapat diblokir.", cancel);
        if (FAILED(hr)) fail(L"Alamat navigasi tidak dapat diverifikasi.", hr);
        return S_OK;
    }
    hr = args->get_NavigationId(&navigationId_);
    if (FAILED(hr)) {
        CleanupHr(args->put_Cancel(TRUE));
        fail(L"Identitas navigasi tidak dapat dibaca.", hr);
        return S_OK;
    }
    trustedNavigation_ = true;
    ++generation_;
    return S_OK;
}
HRESULT Host::navigationCompleted(ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs* args) {
    if (closing_) return S_OK;
    if (!args) { fail(L"Hasil navigasi tidak tersedia.", E_POINTER); return S_OK; }
    UINT64 id = 0;
    HRESULT hr = args->get_NavigationId(&id);
    if (FAILED(hr)) { fail(L"Hasil navigasi tidak dapat diverifikasi.", hr); return S_OK; }
    if (!trustedNavigation_ || id != navigationId_) return S_OK; // Ignore canceled external attempts.
    BOOL success = FALSE;
    hr = args->get_IsSuccess(&success);
    if (FAILED(hr) || !success || !sourceTrusted()) {
        fail(L"Halaman KasirKu tidak dapat dimuat dari folder ui.", FAILED(hr) ? hr : E_FAIL);
        return S_OK;
    }
    if (smoke_ && !smokeSent_) {
        smokeSent_ = true;
        ComPtr<ICoreWebView2ExecuteScriptCompletedHandler> callback(
            new Callback<ICoreWebView2ExecuteScriptCompletedHandler, HRESULT, LPCWSTR>(context_, ScriptExecuted));
        hr = callback.value ? webview_->ExecuteScript(
            L"(()=>{if(window!==window.top||location.href!=='https://kasirku.local/index.html')return false;"
            L"const received=e=>{const r=e.data;if(r&&r.id==='native-smoke'&&r.ok===true&&r.result&&r.result.pong===true){"
            L"chrome.webview.removeEventListener('message',received);"
            L"chrome.webview.postMessage({id:'native-smoke-ack',command:'native.smoke.ack',payload:{}});}};"
            L"chrome.webview.addEventListener('message',received);"
            L"chrome.webview.postMessage({id:'native-smoke',command:'system.ping',payload:{}});return true;})()",
            callback.value) : E_OUTOFMEMORY;
        if (FAILED(hr)) fail(L"Uji komunikasi halaman tidak dapat dimulai.", hr);
    }
    return S_OK;
}

HRESULT Host::postJson(const char* json, size_t length) {
    if (!sourceTrusted()) return E_ACCESSDENIED;
    if (!json || !length || length > kMessageLimit) return E_INVALIDARG;
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, json, static_cast<int>(length), nullptr, 0);
    if (!count) return LastErrorHr();
    HeapBuffer<wchar_t> wide(static_cast<size_t>(count) + 1);
    if (!wide.value) return E_OUTOFMEMORY;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, json, static_cast<int>(length), wide.value, count) != count)
        return LastErrorHr();
    return webview_->PostWebMessageAsJson(wide.value);
}
void Host::reject(const char* code, const char* request, size_t length) {
    if (closing_) return;
    Envelope envelope;
    bool parsed = request && Json(request, length).inspect(envelope);
    static constexpr char nullId[] = "null";
    Slice id = parsed && envelope.id.begin ? envelope.id : Slice{nullId, nullId + 4};
    const size_t idLength = static_cast<size_t>(id.end - id.begin);
    const char prefix[] = "{\"id\":";
    const char middle[] = ",\"ok\":false,\"error\":{\"code\":\"";
    const char suffix[] = "\"}}";
    size_t total = sizeof(prefix) - 1 + idLength + sizeof(middle) - 1 + strlen(code) + sizeof(suffix) - 1;
    if (total > kMessageLimit) { id = {nullId, nullId + 4}; total -= idLength - 4; }
    HeapBuffer<char> response(total + 1);
    if (!response.value) { fail(L"Memori tidak cukup untuk mengirim balasan.", E_OUTOFMEMORY); return; }
    char* out = response.value;
    auto append = [&out](const char* text, size_t bytes) { memcpy(out, text, bytes); out += bytes; };
    append(prefix, sizeof(prefix) - 1);
    append(id.begin, static_cast<size_t>(id.end - id.begin));
    append(middle, sizeof(middle) - 1);
    append(code, strlen(code));
    append(suffix, sizeof(suffix) - 1);
    HRESULT hr = postJson(response.value, total);
    if (FAILED(hr)) fail(L"Balasan tidak dapat dikirim ke halaman.", hr);
}
HRESULT Host::messageReceived(ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) {
    if (closing_ || !args || !sourceTrusted()) return S_OK;
    ComText source, message;
    HRESULT hr = args->get_Source(&source.value);
    if (FAILED(hr) || !source.value || wcscmp(source.value, kUrl)) return S_OK;
    // Source is exact, not merely a same-origin prefix. Frame events are never subscribed.
    hr = args->get_WebMessageAsJson(&message.value);
    if (FAILED(hr) || !message.value) { reject("INVALID_REQUEST"); return S_OK; }
    size_t wideLength = 0;
    while (wideLength <= kMessageLimit && message.value[wideLength]) ++wideLength;
    if (wideLength > kMessageLimit) { reject("REQUEST_TOO_LARGE"); return S_OK; }
    int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, message.value,
        static_cast<int>(wideLength), nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) { reject("INVALID_REQUEST"); return S_OK; }
    if (static_cast<size_t>(bytes) > kMessageLimit) { reject("REQUEST_TOO_LARGE"); return S_OK; }
    Work* item = Work::create(static_cast<size_t>(bytes));
    if (!item) { fail(L"Memori tidak cukup untuk menerima permintaan.", E_OUTOFMEMORY); return S_OK; }
    item->length = static_cast<size_t>(bytes);
    item->generation = generation_;
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, message.value, static_cast<int>(wideLength),
                           item->request(), bytes, nullptr, nullptr) != bytes) {
        delete item;
        reject("INVALID_REQUEST");
        return S_OK;
    }
    Envelope envelope;
    if (!Json(item->request(), item->length).inspect(envelope)) {
        delete item;
        reject("INVALID_REQUEST");
        return S_OK;
    }
    if (smoke_ && envelope.smokeAck && StringEquals(envelope.id, "native-smoke-ack")) {
        // Do not report success merely because an IPC send was queued: the page must receive it.
        delete item;
        if (smokeResponsePosted_) {
            if (GetTickCount64() < smokeDeadline_) close(0);
            else fail(L"Uji komunikasi melewati batas waktu 15 detik.", HRESULT_FROM_WIN32(ERROR_TIMEOUT));
        }
        return S_OK;
    }
    item->smoke = smoke_ && smokeSent_ && !smokeQueued_ && envelope.ping && StringEquals(envelope.id, "native-smoke");
    EnterCriticalSection(&lock_);
    bool accepted = !workerStopping_ && outstanding_ < kQueueLimit;
    if (accepted) {
        pending_[(pendingHead_ + pendingCount_) % kQueueLimit] = item;
        ++pendingCount_;
        ++outstanding_;
        if (!SetEvent(workReady_.value)) workerError_ = GetLastError();
    }
    LeaveCriticalSection(&lock_);
    if (!accepted) { reject("QUEUE_FULL", item->request(), item->length); delete item; }
    else if (item->smoke) smokeQueued_ = true;
    return S_OK;
}

DWORD WINAPI Host::WorkerProc(void* self) { return static_cast<Host*>(self)->work(); }
DWORD Host::work() {
    for (;;) {
        DWORD wait = WaitForSingleObject(workReady_.value, INFINITE);
        if (wait != WAIT_OBJECT_0) {
            DWORD error = wait == WAIT_FAILED ? GetLastError() : ERROR_GEN_FAILURE;
            EnterCriticalSection(&lock_);
            workerError_ = error;
            LeaveCriticalSection(&lock_);
            return 1; // The signaled thread handle wakes the UI even if an event has failed.
        }
        for (;;) {
            EnterCriticalSection(&lock_);
            if (!pendingCount_) {
                bool stop = workerStopping_;
                bool resetFailed = !stop && !ResetEvent(workReady_.value);
                if (resetFailed) workerError_ = GetLastError();
                LeaveCriticalSection(&lock_);
                if (resetFailed) return 1;
                if (stop) return 0;
                break;
            }
            Work* item = pending_[pendingHead_];
            pending_[pendingHead_] = nullptr;
            pendingHead_ = (pendingHead_ + 1) % kQueueLimit;
            --pendingCount_;
            LeaveCriticalSection(&lock_);

            // The only call site, on the only worker. No COM, HWND manipulation, or DB calls on the UI thread.
            item->response = kasirku_dispatch(item->request());

            EnterCriticalSection(&lock_);
            bool notify = finishedCount_ == 0;
            finished_[(finishedHead_ + finishedCount_) % kQueueLimit] = item;
            ++finishedCount_;
            LeaveCriticalSection(&lock_);
            if (notify) {
                // Bounded rings retain ownership even when message posting fails.
                if (!PostMessageW(workerWindow_, kResultsMessage, 0, 0)) {
                    DWORD error = GetLastError();
                    EnterCriticalSection(&lock_);
                    workerError_ = error;
                    LeaveCriticalSection(&lock_);
                }
                if (!SetEvent(resultsReady_.value)) {
                    DWORD error = GetLastError();
                    EnterCriticalSection(&lock_);
                    workerError_ = error;
                    LeaveCriticalSection(&lock_);
                    return 1;
                }
            }
        }
    }
}
void Host::drainResults() {
    for (;;) {
        EnterCriticalSection(&lock_);
        DWORD workerError = workerError_;
        Work* item = nullptr;
        if (finishedCount_) {
            item = finished_[finishedHead_];
            finished_[finishedHead_] = nullptr;
            finishedHead_ = (finishedHead_ + 1) % kQueueLimit;
            --finishedCount_;
            --outstanding_;
        }
        LeaveCriticalSection(&lock_);
        if (workerError) fail(L"Antrean komunikasi aplikasi gagal.", HRESULT_FROM_WIN32(workerError));
        if (!item) return;
        if (!closing_ && item->generation == generation_ && sourceTrusted()) {
            size_t bytes = BoundedLength(item->response);
            Envelope response;
            bool valid = item->response && bytes && bytes <= kMessageLimit &&
                         Json(item->response, bytes).inspect(response) && response.id.begin && response.okBoolean;
            if (!valid) {
                reject(bytes > kMessageLimit ? "RESPONSE_TOO_LARGE" : "INVALID_RESPONSE", item->request(), item->length);
                if (item->smoke) fail(L"Uji komunikasi menerima balasan yang tidak sah.", E_FAIL);
            } else {
                HRESULT hr = postJson(item->response, bytes);
                // Release Zig's allocation only AFTER PostWebMessageAsJson has copied the text.
                bool smokeSuccess = item->smoke && StringEquals(response.id, "native-smoke") && response.ok && response.pong;
                if (FAILED(hr)) fail(L"Balasan tidak dapat dikirim ke halaman.", hr);
                else if (item->smoke) {
                    if (smokeSuccess) smokeResponsePosted_ = true;
                    else fail(L"Uji system.ping gagal: balasan bukan pong.", E_FAIL);
                }
            }
        }
        delete item;
    }
}

void Host::detach() {
    if (detached_) return;
    detached_ = true;
    // Pending callbacks retain Context so late controllers can close without accessing Host.
    if (context_) context_->host = nullptr;
    Unsubscribe(webview_.value, &ICoreWebView2::remove_NavigationStarting, navigation_);
    Unsubscribe(webview_.value, &ICoreWebView2::remove_FrameNavigationStarting, frames_);
    Unsubscribe(webview_.value, &ICoreWebView2::remove_NavigationCompleted, completed_);
    Unsubscribe(webview_.value, &ICoreWebView2::remove_WebMessageReceived, messages_);
    Unsubscribe(webview_.value, &ICoreWebView2::remove_PermissionRequested, permissions_);
    Unsubscribe(webview_.value, &ICoreWebView2::remove_NewWindowRequested, windows_);
    Unsubscribe(webview4_.value, &ICoreWebView2_4::remove_DownloadStarting, downloads_);
    Unsubscribe(webview_.value, &ICoreWebView2::remove_ProcessFailed, processes_);
    Unsubscribe(webview_.value, &ICoreWebView2::remove_SourceChanged, sources_);
    if (controller_.value) CleanupHr(controller_->Close());
    controller4_.reset();
    webview4_.reset();
    webview_.reset();
    controller_.reset();
    environment_.reset();
}
Host::~Host() {
    // run() has observed the worker handle signaled, including all dispatch calls.
    detach();
    for (unsigned i = 0; i < kQueueLimit; ++i) { delete pending_[i]; delete finished_[i]; }
    if (window_ && IsWindow(window_)) DestroyWindow(window_);
    if (classRegistered_) UnregisterClassW(kClass, GetModuleHandleW(nullptr));
    if (lockInitialized_) DeleteCriticalSection(&lock_);
    if (context_) context_->release();
}

LRESULT CALLBACK Host::WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    Host* host = reinterpret_cast<Host*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        host = static_cast<Host*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
        SetLastError(ERROR_SUCCESS);
        if (!SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(host)) && GetLastError()) {
            host->fail(L"Data jendela KasirKu tidak dapat disimpan.", LastErrorHr());
            return FALSE;
        }
        host->window_ = window;
    }
    if (!host) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
        case WM_CLOSE: host->close(host->smoke_ ? 1 : 0); return 0;
        case WM_DESTROY:
            if (!host->closing_) host->close(host->smoke_ ? 1 : 0);
            return 0; // The private pump exits after joining, not immediately on WM_DESTROY.
        case WM_NCDESTROY:
            SetWindowLongPtrW(window, GWLP_USERDATA, 0);
            host->window_ = nullptr;
            return DefWindowProcW(window, message, wparam, lparam);
        case WM_GETMINMAXINFO: {
            UINT dpi = GetDpiForWindow(window);
            if (!dpi) dpi = host->dpi_;
            RECT bounds{0, 0, MulDiv(1000, static_cast<int>(dpi), 96), MulDiv(640, static_cast<int>(dpi), 96)};
            if (!AdjustWindowRectExForDpi(&bounds, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi)) {
                host->fail(L"Ukuran minimum jendela tidak dapat diatur.", LastErrorHr());
                return 0;
            }
            auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
            info->ptMinTrackSize.x = bounds.right - bounds.left;
            info->ptMinTrackSize.y = bounds.bottom - bounds.top;
            return 0;
        }
        case WM_DPICHANGED: {
            host->dpi_ = HIWORD(wparam);
            const RECT* bounds = reinterpret_cast<const RECT*>(lparam);
            if (!SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
                              bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE))
                host->fail(L"Skala jendela tidak dapat diperbarui.", LastErrorHr());
            return 0;
        }
        case WM_SIZE:
        case WM_MOVE:
            if (message != WM_SIZE || wparam != SIZE_MINIMIZED) {
                HRESULT hr = host->resize();
                if (FAILED(hr)) host->fail(L"Ukuran halaman tidak dapat diperbarui.", hr);
            }
            return 0;
        case WM_SETFOCUS:
            if (host->controller_.value && !host->closing_) {
                HRESULT hr = host->controller_->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
                if (FAILED(hr)) host->fail(L"Fokus halaman tidak dapat diatur.", hr);
            }
            return 0;
        case WM_TIMER:
            if (wparam == kSmokeTimer && host->smoke_ && !host->closing_)
                host->fail(L"Uji komunikasi melewati batas waktu 15 detik.", HRESULT_FROM_WIN32(ERROR_TIMEOUT));
            return 0;
        case kResultsMessage:
            if (host->lockInitialized_) host->drainResults();
            return 0;
        default: return DefWindowProcW(window, message, wparam, lparam);
    }
}

int Host::run(const wchar_t* dataDir) {
    HRESULT hr = prepare(dataDir);
    if (FAILED(hr)) fail(L"KasirKu tidak dapat menyiapkan folder data atau WebView2.", hr);
    if (!closing_) {
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = WindowProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
        wc.lpszClassName = kClass;
        if (!RegisterClassExW(&wc)) fail(L"Kelas jendela KasirKu tidak dapat dibuat.", LastErrorHr());
        else classRegistered_ = true;
    }
    if (!closing_) {
        dpi_ = GetDpiForSystem();
        if (!dpi_) dpi_ = 96;
        RECT bounds{0, 0, MulDiv(1280, static_cast<int>(dpi_), 96), MulDiv(800, static_cast<int>(dpi_), 96)};
        RECT workArea{};
        if (!AdjustWindowRectExForDpi(&bounds, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi_) ||
            !SystemParametersInfoW(SPI_GETWORKAREA, 0, &workArea, 0)) {
            fail(L"Ukuran jendela KasirKu tidak dapat diatur.", LastErrorHr());
        } else {
            const LONG availableWidth = workArea.right - workArea.left;
            const LONG availableHeight = workArea.bottom - workArea.top;
            const LONG width = bounds.right - bounds.left < availableWidth ? bounds.right - bounds.left : availableWidth;
            const LONG height = bounds.bottom - bounds.top < availableHeight ? bounds.bottom - bounds.top : availableHeight;
            if (!CreateWindowExW(0, kClass, L"KasirKu", WS_OVERLAPPEDWINDOW,
                                 workArea.left + (availableWidth - width) / 2, workArea.top + (availableHeight - height) / 2,
                                 width, height, nullptr, nullptr, GetModuleHandleW(nullptr), this))
                fail(L"Jendela KasirKu tidak dapat dibuat.", LastErrorHr());
        }
    }
    if (!closing_) {
        workerWindow_ = window_;
        worker_.value = CreateThread(nullptr, 0, WorkerProc, this, 0, nullptr);
        if (!worker_.value) fail(L"Pekerja basis data tidak dapat dimulai.", LastErrorHr());
    }
    if (!closing_) {
        ShowWindow(window_, SW_SHOW);
        if (smoke_) {
            smokeDeadline_ = GetTickCount64() + 15000;
            if (!SetTimer(window_, kSmokeTimer, 15000, nullptr))
                fail(L"Batas waktu uji tidak dapat diaktifkan.", LastErrorHr());
        }
    }
    if (!closing_) {
        using Create = HRESULT (STDAPICALLTYPE*)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
        Create create = reinterpret_cast<Create>(GetProcAddress(context_->loader, "CreateCoreWebView2EnvironmentWithOptions"));
        ComPtr<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler> callback(
            new Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, HRESULT, ICoreWebView2Environment*>(context_, Environment));
        hr = !create ? HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND) : !callback.value ? E_OUTOFMEMORY :
            create(nullptr, profilePath_.value, nullptr, callback.value);
        if (FAILED(hr)) fail(kRuntimeError, hr);
    }
    bool resultsEventUsable = true;
    while (worker_.value) {
        // WM_TIMER is low priority; enforce the same deadline even under a busy message queue.
        if (smoke_ && !closing_ && smokeDeadline_ && GetTickCount64() >= smokeDeadline_)
            WindowProc(window_, WM_TIMER, kSmokeTimer, 0);
        if (closing_) {
            detach();
            if (window_) ShowWindow(window_, SW_HIDE);
        }
        // Wait for both Win32 input and worker notifications: never synchronously wait on DB work.
        HANDLE handles[] = {worker_.value, resultsReady_.value};
        DWORD wait = MsgWaitForMultipleObjectsEx(resultsEventUsable ? 2 : 1, handles,
                                                INFINITE, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (wait == WAIT_FAILED) {
            fail(L"Pompa pesan Windows gagal.", LastErrorHr());
            // Even the failure path pumps messages while joining; omit a failed optional event.
            resultsEventUsable = false;
            if (WaitForSingleObject(worker_.value, 0) == WAIT_OBJECT_0) {
                drainResults();
                break;
            }
            SwitchToThread();
        }
        if (resultsEventUsable && wait == WAIT_OBJECT_0 + 1) drainResults();
        if (wait == WAIT_OBJECT_0) {
            if (!closing_) fail(L"Pekerja basis data berhenti tak terduga.", E_FAIL);
            drainResults();
            break; // A signaled thread handle is the join; no worker can access Host now.
        }
        MSG message{};
        // A finite batch also lets the thread/event wakeups progress under message floods.
        for (unsigned i = 0; i < 64 && PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE); ++i) {
            if (message.message == WM_QUIT) { close(message.wParam ? static_cast<int>(message.wParam) : (smoke_ ? 1 : 0)); continue; }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    detach();
    if (error_ && !smoke_) {
        wchar_t text[1024];
        _snwprintf(text, sizeof(text) / sizeof(text[0]), L"%ls\n\nKode kesalahan: 0x%08lX", error_, static_cast<unsigned long>(errorHr_));
        text[sizeof(text) / sizeof(text[0]) - 1] = 0;
        MessageBoxW(nullptr, text, L"KasirKu", MB_OK | MB_ICONERROR);
    }
    return exitCode_;
}
#undef RETURN_IF_FAILED
} // namespace

extern "C" int kasirku_host_run(const wchar_t* data_dir, bool smoke) {
    // Caller must serialize invocations and keep Zig's dispatcher/database alive until return.
    DpiScope dpi;
    if (!dpi.previous) {
        if (!smoke) MessageBoxW(nullptr, L"KasirKu memerlukan Windows 10/11 dengan dukungan skala DPI per monitor.", L"KasirKu", MB_OK | MB_ICONERROR);
        return 1;
    }
    Apartment apartment;
    if (FAILED(apartment.hr)) {
        LogHr(L"COM STA tidak dapat dimulai", apartment.hr);
        if (!smoke) MessageBoxW(nullptr, L"Antarmuka KasirKu harus dijalankan pada utas Windows STA.", L"KasirKu", MB_OK | MB_ICONERROR);
        return 1;
    }
    Host* host = new Host(smoke);
    if (!host) {
        if (!smoke) MessageBoxW(nullptr, L"Memori tidak cukup untuk membuka KasirKu.", L"KasirKu", MB_OK | MB_ICONERROR);
        return 1;
    }
    int result = host->run(data_dir);
    delete host;
    return result;
}
