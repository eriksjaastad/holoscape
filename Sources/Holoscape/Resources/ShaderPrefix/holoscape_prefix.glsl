#version 430 core
#define HOLOSCAPE 1

layout(binding = 1, std140) uniform Globals {
    uniform vec3  iResolution;
    uniform float iTime;
    uniform float iTimeDelta;
    uniform float iFrameRate;
    uniform int   iFrame;
    uniform float iChannelTime[4];
    uniform vec3  iChannelResolution[4];
    uniform vec4  iMouse;
    uniform vec4  iDate;
    uniform float iSampleRate;
    uniform vec4  iCurrentCursor;
    uniform vec4  iPreviousCursor;
    uniform vec4  iCurrentCursorColor;
    uniform vec4  iPreviousCursorColor;
    uniform int   iCurrentCursorStyle;
    uniform int   iPreviousCursorStyle;
    uniform int   iCursorVisible;
    uniform float iTimeCursorChange;
    uniform float iTimeFocus;
    uniform int iFocus;
    uniform vec3  iPalette[256];
    uniform vec3  iBackgroundColor;
    uniform vec3  iForegroundColor;
    uniform vec3  iCursorColor;
    uniform vec3  iCursorText;
    uniform vec3  iSelectionForegroundColor;
    uniform vec3  iSelectionBackgroundColor;

    // --- Holoscape extension: output events ---
    uniform int   iOutputEventCount;        // monotonic counter; changes ⇒ new output
    uniform float iTimeLastOutput;          // iTime stamp of most recent new-output event

    // --- Holoscape extension: command lifecycle ---
    uniform int   iCommandState;            // 0=idle, 1=running, 2=completed
    uniform int   iPreviousCommandState;
    uniform int   iLastCommandExitCode;     // meaningful only when iCommandState == 2
    uniform float iTimeCommandStart;
    uniform float iTimeCommandEnd;

    // --- Holoscape extension: agent state (the differentiator) ---
    uniform int   iAgentState;              // 0=idle, 1=thinking, 2=toolUse, 3=error
    uniform int   iPreviousAgentState;
    uniform float iTimeAgentStateChange;    // stamped on every transition (both directions)

    // --- Holoscape extension: channel state ---
    uniform int   iChannelId;               // stable hash of channel identity
    uniform int   iChannelIsActive;         // 1 if foreground channel, else 0
    uniform int   iChannelUnread;           // unread count, clamped to int range

    // --- Holoscape extension: notifications ---
    uniform int   iNotificationKind;        // 0=none, 1=info, 2=warn, 3=error
    uniform float iTimeLastNotification;
};

#define CURSORSTYLE_BLOCK        0
#define CURSORSTYLE_BLOCK_HOLLOW 1
#define CURSORSTYLE_BAR          2
#define CURSORSTYLE_UNDERLINE    3
#define CURSORSTYLE_LOCK         4

layout(binding = 0) uniform sampler2D iChannel0;

// These are unused currently by Ghostty:
// layout(binding = 1) uniform sampler2D iChannel1;
// layout(binding = 2) uniform sampler2D iChannel2;
// layout(binding = 3) uniform sampler2D iChannel3;

layout(location = 0) in vec4 gl_FragCoord;
layout(location = 0) out vec4 _fragColor;

#define texture2D texture

void mainImage( out vec4 fragColor, in vec2 fragCoord );
void main() { mainImage (_fragColor, gl_FragCoord.xy); }
