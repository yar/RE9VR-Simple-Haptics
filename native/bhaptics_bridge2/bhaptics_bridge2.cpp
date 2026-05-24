#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <windows.h>
#include <winhttp.h>

#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <mutex>
#include <string>

extern "C" {
#include "reframework/API.h"
#include "lua.h"
}

namespace {

constexpr wchar_t kPlayerHost[] = L"127.0.0.1";
constexpr INTERNET_PORT kPlayerPort = 15881;
constexpr wchar_t kPlayerPath[] =
    L"/v2/feedbacks?app_id=com.re9vr.simple_haptics.bridge2&app_name=RE9VR%20Simple%20Haptics%20Bridge2";
constexpr DWORD kWinHttpTimeoutMs = 250;
constexpr unsigned int kBackoffAfterFailedConnectAttempts = 3;
constexpr ULONGLONG kInitialConnectRetryDelayMs = 5000;
constexpr ULONGLONG kBackoffConnectRetryDelayMs = 15000;

const REFrameworkPluginFunctions* g_ref = nullptr;

void log_info(const char* format, ...) {
    if (g_ref == nullptr || g_ref->log_info == nullptr) {
        return;
    }

    char buffer[2048]{};
    va_list args;
    va_start(args, format);
    vsnprintf_s(buffer, sizeof(buffer), _TRUNCATE, format, args);
    va_end(args);
    g_ref->log_info("[bhaptics_bridge2] %s", buffer);
}

std::string last_win32_error(const char* prefix, DWORD error = GetLastError()) {
    char* message = nullptr;
    FormatMessageA(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr,
        error,
        MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        reinterpret_cast<LPSTR>(&message),
        0,
        nullptr);

    std::string result = prefix;
    result += " ";
    result += std::to_string(error);
    if (message != nullptr) {
        result += ": ";
        result += message;
        LocalFree(message);
    }
    while (!result.empty() && (result.back() == '\r' || result.back() == '\n')) {
        result.pop_back();
    }
    return result;
}

std::string lua_string(lua_State* L, int index) {
    size_t length = 0;
    const char* value = lua_tolstring(L, index, &length);
    if (value == nullptr) {
        return {};
    }
    return std::string(value, length);
}

std::string json_escape(std::string_view value) {
    std::string out;
    out.reserve(value.size() + 8);

    for (unsigned char ch : value) {
        switch (ch) {
        case '\\':
            out += "\\\\";
            break;
        case '"':
            out += "\\\"";
            break;
        case '\b':
            out += "\\b";
            break;
        case '\f':
            out += "\\f";
            break;
        case '\n':
            out += "\\n";
            break;
        case '\r':
            out += "\\r";
            break;
        case '\t':
            out += "\\t";
            break;
        default:
            if (ch < 0x20) {
                char escaped[8]{};
                snprintf(escaped, sizeof(escaped), "\\u%04X", ch);
                out += escaped;
            } else {
                out.push_back(static_cast<char>(ch));
            }
            break;
        }
    }

    return out;
}

std::string json_object_or_empty(std::string value) {
    value.erase(value.begin(), std::find_if(value.begin(), value.end(), [](unsigned char ch) {
        return ch > ' ';
    }));
    value.erase(std::find_if(value.rbegin(), value.rend(), [](unsigned char ch) {
        return ch > ' ';
    }).base(), value.end());
    if (value.empty()) {
        return "{}";
    }
    return value;
}

class Bridge {
public:
    static Bridge& instance() {
        static Bridge bridge;
        return bridge;
    }

    bool ensure_connected() {
        std::lock_guard lock{m_mutex};
        return ensure_connected_locked();
    }

    bool register_project(std::string key, std::string project_json, double duration) {
        (void)duration;
        if (key.empty() || project_json.empty()) {
            set_last_error("register_project missing key or project_json");
            return false;
        }

        std::string payload = "{\"Register\":[{\"Key\":\"";
        payload += json_escape(key);
        payload += "\",\"Project\":";
        payload += project_json;
        payload += "}],\"Submit\":[]}";

        return send_command("REGISTER_PROJECT " + key, payload);
    }

    bool submit_registered(std::string key) {
        if (key.empty()) {
            set_last_error("submit_registered missing key");
            return false;
        }

        std::string payload = "{\"Register\":[],\"Submit\":[{\"Type\":\"key\",\"Key\":\"";
        payload += json_escape(key);
        payload += "\"}]}";

        return send_command("SUBMIT_REGISTERED " + key, payload);
    }

    bool submit_registered_with_options(
        std::string key,
        std::string alt_key,
        std::string scale_json,
        std::string rotation_json) {
        if (key.empty()) {
            set_last_error("submit_registered_with_options missing key");
            return false;
        }

        std::string payload = "{\"Register\":[],\"Submit\":[{\"Type\":\"key\",\"Key\":\"";
        payload += json_escape(key);
        payload += "\",\"Parameters\":{\"altKey\":\"";
        payload += json_escape(alt_key);
        payload += "\",\"scaleOption\":";
        payload += json_object_or_empty(std::move(scale_json));
        payload += ",\"rotationOption\":";
        payload += json_object_or_empty(std::move(rotation_json));
        payload += "}}]}";

        return send_command("SUBMIT_REGISTERED_WITH_OPTIONS " + key, payload);
    }

    bool submit_frame(std::string key, std::string frame_json) {
        if (key.empty() || frame_json.empty()) {
            set_last_error("submit_frame missing key or frame_json");
            return false;
        }

        std::string payload = "{\"Submit\":[{\"Type\":\"frame\",\"Key\":\"";
        payload += json_escape(key);
        payload += "\",\"Frame\":";
        payload += frame_json;
        payload += "}]}";

        return send_command("SUBMIT_FRAME " + key, payload);
    }

    bool send_raw(std::string payload) {
        if (payload.empty()) {
            set_last_error("send_raw missing payload");
            return false;
        }

        return send_command("SEND_RAW", payload);
    }

    bool trigger_connection_pulse() {
        const char* front = "{\"Submit\":[{\"Type\":\"frame\",\"Key\":\"__connection_front\","
                            "\"Frame\":{\"position\":\"VestFront\",\"dotPoints\":[{\"index\":5,"
                            "\"intensity\":100}],\"durationMillis\":100}}]}";
        const char* back = "{\"Submit\":[{\"Type\":\"frame\",\"Key\":\"__connection_back\","
                           "\"Frame\":{\"position\":\"VestBack\",\"dotPoints\":[{\"index\":5,"
                           "\"intensity\":100}],\"durationMillis\":100}}]}";

        return send_command("CONNECTION_PULSE front", front) &&
            send_command("CONNECTION_PULSE back", back);
    }

    bool is_connected() const {
        std::lock_guard lock{m_mutex};
        return m_websocket != nullptr && m_connected;
    }

    std::string last_error() const {
        std::lock_guard lock{m_mutex};
        return m_last_error;
    }

    std::string last_command() const {
        std::lock_guard lock{m_mutex};
        return m_last_command;
    }

    std::string phase() const {
        std::lock_guard lock{m_mutex};
        return m_phase;
    }

    void shutdown() {
        std::lock_guard lock{m_mutex};
        close_locked();
    }

private:
    bool send_command(std::string command, std::string_view payload) {
        std::lock_guard lock{m_mutex};
        m_last_command = std::move(command);

        if (!ensure_connected_locked()) {
            return false;
        }

        if (send_text_locked(payload)) {
            return true;
        }

        close_locked();
        if (!ensure_connected_locked()) {
            return false;
        }

        return send_text_locked(payload);
    }

    bool send_text_locked(std::string_view payload) {
        const DWORD result = WinHttpWebSocketSend(
            m_websocket,
            WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
            const_cast<char*>(payload.data()),
            static_cast<DWORD>(payload.size()));

        if (result == ERROR_SUCCESS) {
            m_last_error.clear();
            return true;
        }

        m_connected = false;
        m_phase = "send_failed";
        m_last_error = last_win32_error("WinHttpWebSocketSend failed:", result);
        return false;
    }

    bool ensure_connected_locked() {
        if (m_websocket != nullptr && m_connected) {
            return true;
        }

        const ULONGLONG now = GetTickCount64();
        if (m_next_connect_attempt_ms != 0 && now < m_next_connect_attempt_ms) {
            m_phase = "retry_wait";
            return false;
        }

        close_locked();
        m_phase = "connecting";

        m_session = WinHttpOpen(
            L"bhaptics_bridge2/1.1",
            WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
            WINHTTP_NO_PROXY_NAME,
            WINHTTP_NO_PROXY_BYPASS,
            0);
        if (m_session == nullptr) {
            m_phase = "error";
            m_last_error = last_win32_error("WinHttpOpen failed:");
            defer_reconnect_locked();
            return false;
        }

        WinHttpSetTimeouts(
            m_session,
            kWinHttpTimeoutMs,
            kWinHttpTimeoutMs,
            kWinHttpTimeoutMs,
            kWinHttpTimeoutMs);

        m_connect = WinHttpConnect(m_session, kPlayerHost, kPlayerPort, 0);
        if (m_connect == nullptr) {
            m_phase = "error";
            m_last_error = last_win32_error("WinHttpConnect failed:");
            close_locked();
            defer_reconnect_locked();
            return false;
        }

        HINTERNET request = WinHttpOpenRequest(
            m_connect,
            L"GET",
            kPlayerPath,
            nullptr,
            WINHTTP_NO_REFERER,
            WINHTTP_DEFAULT_ACCEPT_TYPES,
            0);
        if (request == nullptr) {
            m_phase = "error";
            m_last_error = last_win32_error("WinHttpOpenRequest failed:");
            close_locked();
            defer_reconnect_locked();
            return false;
        }

        bool ok = true;
        if (!WinHttpSetOption(request, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nullptr, 0)) {
            m_last_error = last_win32_error("WinHttpSetOption(UPGRADE_TO_WEB_SOCKET) failed:");
            ok = false;
        }
        if (ok && !WinHttpSendRequest(
                      request,
                      WINHTTP_NO_ADDITIONAL_HEADERS,
                      0,
                      WINHTTP_NO_REQUEST_DATA,
                      0,
                      0,
                      0)) {
            m_last_error = last_win32_error("WinHttpSendRequest failed:");
            ok = false;
        }
        if (ok && !WinHttpReceiveResponse(request, nullptr)) {
            m_last_error = last_win32_error("WinHttpReceiveResponse failed:");
            ok = false;
        }

        if (ok) {
            m_websocket = WinHttpWebSocketCompleteUpgrade(request, 0);
            if (m_websocket == nullptr) {
                m_last_error = last_win32_error("WinHttpWebSocketCompleteUpgrade failed:");
                ok = false;
            }
        }

        WinHttpCloseHandle(request);

        if (!ok) {
            m_phase = "error";
            close_locked();
            defer_reconnect_locked();
            return false;
        }

        m_connected = true;
        m_next_connect_attempt_ms = 0;
        m_failed_connect_attempts = 0;
        m_phase = "connected";
        m_last_error.clear();
        log_info("Connected to bHaptics Player websocket");
        return true;
    }

    void set_last_error(std::string error) {
        std::lock_guard lock{m_mutex};
        m_last_error = std::move(error);
        m_phase = "error";
    }

    void close_locked() {
        if (m_websocket != nullptr) {
            WinHttpCloseHandle(m_websocket);
            m_websocket = nullptr;
        }
        if (m_connect != nullptr) {
            WinHttpCloseHandle(m_connect);
            m_connect = nullptr;
        }
        if (m_session != nullptr) {
            WinHttpCloseHandle(m_session);
            m_session = nullptr;
        }
        m_connected = false;
        if (m_phase != "error") {
            m_phase = "disconnected";
        }
    }

    void defer_reconnect_locked() {
        ++m_failed_connect_attempts;
        const ULONGLONG retry_delay_ms =
            m_failed_connect_attempts >= kBackoffAfterFailedConnectAttempts
                ? kBackoffConnectRetryDelayMs
                : kInitialConnectRetryDelayMs;
        m_next_connect_attempt_ms = GetTickCount64() + retry_delay_ms;
    }

private:
    mutable std::mutex m_mutex;
    HINTERNET m_session{};
    HINTERNET m_connect{};
    HINTERNET m_websocket{};
    bool m_connected{};
    ULONGLONG m_next_connect_attempt_ms{};
    unsigned int m_failed_connect_attempts{};
    std::string m_phase{"initialized"};
    std::string m_last_error{};
    std::string m_last_command{};
};

int l_ensure_connected(lua_State* L) {
    lua_pushboolean(L, Bridge::instance().ensure_connected() ? 1 : 0);
    return 1;
}

int l_register_project(lua_State* L) {
    const std::string key = lua_string(L, 1);
    const std::string project_json = lua_string(L, 2);
    const double duration = lua_tonumber(L, 3);
    lua_pushboolean(L, Bridge::instance().register_project(key, project_json, duration) ? 1 : 0);
    return 1;
}

int l_submit_registered(lua_State* L) {
    const std::string key = lua_string(L, 1);
    lua_pushboolean(L, Bridge::instance().submit_registered(key) ? 1 : 0);
    return 1;
}

int l_submit_registered_with_options(lua_State* L) {
    const std::string key = lua_string(L, 1);
    const std::string alt_key = lua_string(L, 2);
    const std::string scale_json = lua_string(L, 3);
    const std::string rotation_json = lua_string(L, 4);
    lua_pushboolean(
        L,
        Bridge::instance()
            .submit_registered_with_options(key, alt_key, scale_json, rotation_json)
            ? 1
            : 0);
    return 1;
}

int l_submit_frame(lua_State* L) {
    const std::string key = lua_string(L, 1);
    const std::string frame_json = lua_string(L, 2);
    lua_pushboolean(L, Bridge::instance().submit_frame(key, frame_json) ? 1 : 0);
    return 1;
}

int l_send_raw(lua_State* L) {
    const std::string payload = lua_string(L, 1);
    lua_pushboolean(L, Bridge::instance().send_raw(payload) ? 1 : 0);
    return 1;
}

int l_trigger_connection_pulse(lua_State* L) {
    lua_pushboolean(L, Bridge::instance().trigger_connection_pulse() ? 1 : 0);
    return 1;
}

int l_is_connected(lua_State* L) {
    lua_pushboolean(L, Bridge::instance().is_connected() ? 1 : 0);
    return 1;
}

void set_table_bool(lua_State* L, const char* key, bool value) {
    lua_pushboolean(L, value ? 1 : 0);
    lua_setfield(L, -2, key);
}

void set_table_string(lua_State* L, const char* key, const std::string& value) {
    lua_pushstring(L, value.c_str());
    lua_setfield(L, -2, key);
}

int l_get_status(lua_State* L) {
    const bool connected = Bridge::instance().is_connected();
    lua_createtable(L, 0, 10);
    set_table_bool(L, "ready", true);
    set_table_bool(L, "connected", connected);
    set_table_bool(L, "directLua", true);
    set_table_string(L, "mode", "lua_bridge2");
    set_table_string(L, "phase", Bridge::instance().phase());
    set_table_string(L, "lastError", Bridge::instance().last_error());
    set_table_string(L, "lastCommand", Bridge::instance().last_command());
    set_table_string(L, "queuePath", "");
    set_table_string(L, "statusPath", "");
    set_table_string(L, "version", "1.1");
    return 1;
}

void set_function(lua_State* L, const char* name, lua_CFunction fn) {
    lua_pushcclosure(L, fn, 0);
    lua_setfield(L, -2, name);
}

void publish_bridge(lua_State* L) {
    if (L == nullptr) {
        return;
    }

    const int top = lua_gettop(L);
    lua_createtable(L, 0, 11);
    set_function(L, "ensure_connected", l_ensure_connected);
    set_function(L, "register_project", l_register_project);
    set_function(L, "submit_registered", l_submit_registered);
    set_function(L, "submit_registered_with_options", l_submit_registered_with_options);
    set_function(L, "submit_frame", l_submit_frame);
    set_function(L, "send_raw", l_send_raw);
    set_function(L, "trigger_connection_pulse", l_trigger_connection_pulse);
    set_function(L, "is_connected", l_is_connected);
    set_function(L, "get_status", l_get_status);
    set_table_string(L, "name", "bhaptics_bridge2");
    set_table_string(L, "mode", "lua_bridge2");

    lua_pushvalue(L, -1);
    lua_setglobal(L, "BhapticsBridge");
    lua_setglobal(L, "bhaptics_bridge");

    lua_settop(L, top);
    log_info("Published Lua bridge globals: BhapticsBridge, bhaptics_bridge");
}

void on_lua_state_created(lua_State* L) {
    publish_bridge(L);
}

void on_lua_state_destroyed(lua_State*) {}

} // namespace

extern "C" __declspec(dllexport) void reframework_plugin_required_version(
    REFrameworkPluginVersion* version) {
    version->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    version->minor = REFRAMEWORK_PLUGIN_VERSION_MINOR;
    version->patch = REFRAMEWORK_PLUGIN_VERSION_PATCH;
    version->game_name = nullptr;
}

extern "C" __declspec(dllexport) bool reframework_plugin_initialize(
    const REFrameworkPluginInitializeParam* param) {
    if (param == nullptr || param->functions == nullptr) {
        return false;
    }

    g_ref = param->functions;
    if (param->functions->on_lua_state_created != nullptr) {
        param->functions->on_lua_state_created(on_lua_state_created);
    }
    if (param->functions->on_lua_state_destroyed != nullptr) {
        param->functions->on_lua_state_destroyed(on_lua_state_destroyed);
    }

    log_info("Initialized - direct Lua websocket bridge ready");
    return true;
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
    }
    return TRUE;
}
