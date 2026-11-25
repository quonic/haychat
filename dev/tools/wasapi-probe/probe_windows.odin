#+build windows
package wasapi_probe

// The WASAPI side of the probe. vendor:windows/wasapi (in the pinned Odin) declares
// IMMDeviceEnumerator, IMMDevice, IMMNotificationClient and IAudioClient to IAudioClient3;
// the interfaces it lacks (IAudioCaptureClient, IAudioEffectsManager,
// IAcousticEchoCancellationControl) and a PROPVARIANT of the right size are declared here
// from the Windows SDK 10.0.26100 headers (audioclient.h, mmdeviceapi.h, ksmedia.h).

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "core:time"
import SDL "vendor:sdl3"
import "vendor:windows/wasapi"

IID_IAudioClient2 := win.IID{
	0x726778CD,
	0xF60A,
	0x4EDA,
	{0x82, 0xDE, 0xE4, 0x76, 0x10, 0xCD, 0x78, 0xAA},
}
IID_IAudioClient3 := win.IID{
	0x7ED4EE07,
	0x8E67,
	0x4CD4,
	{0x8C, 0x1A, 0x2B, 0x7A, 0x59, 0x87, 0xAD, 0x42},
}
IID_IAudioCaptureClient := win.IID{
	0xC8ADBD64,
	0xE71E,
	0x48A0,
	{0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17},
}
IID_IAudioEffectsManager := win.IID{
	0x4460B3AE,
	0x4B44,
	0x4527,
	{0x86, 0x76, 0x75, 0x48, 0xA8, 0xAC, 0xD2, 0x60},
}
IID_IAcousticEchoCancellationControl := win.IID{
	0xF4AE25B5,
	0xAAA3,
	0x437D,
	{0xB6, 0xB3, 0xDB, 0xBE, 0x2D, 0x0E, 0x95, 0x49},
}
IID_IMMNotificationClient := win.IID{
	0x7991EEC9,
	0x7E89,
	0x4D85,
	{0x83, 0x90, 0x6C, 0x70, 0x3C, 0xEC, 0x60, 0xC0},
}
KSDATAFORMAT_SUBTYPE_PCM := win.GUID{
	0x00000001,
	0x0000,
	0x0010,
	{0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71},
}

PKEY_Device_FriendlyName := win.PROPERTYKEY{
	{0xA45C254E, 0xDF1C, 0x4EFD, {0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0}},
	14,
}
// PKEY_AudioEndpoint_Disable_SysFx: 1 when "Audio enhancements" are off for the endpoint.
PKEY_AudioEndpoint_Disable_SysFx := win.PROPERTYKEY{
	{0x1DA5D803, 0xD492, 0x4EDD, {0x8C, 0x23, 0xE0, 0xC0, 0xFF, 0xEE, 0x7F, 0x0E}},
	5,
}

DEVICE_STATE_ACTIVE :: 0x1
DEVICE_STATEMASK_ALL :: 0xF
STGM_READ :: 0
VT_UI4 :: 19
VT_LPWSTR :: 31
AUDCLNT_S_BUFFER_EMPTY :: 0x08890001
AUDCLNT_E_DEVICE_INVALIDATED :: 0x88890004
REFTIMES_PER_MS :: 10000
E_NOINTERFACE :: win.HRESULT(-2147467262) // 0x80004002
// WAVE_FORMAT_PCM, which vendor:windows/wasapi's WAVE_FORMAT enum leaves out.
WAVE_FORMAT_PCM :: wasapi.WAVE_FORMAT(0x0001)

// PropVariant is PROPVARIANT's real 24-byte layout on x64; core:sys/windows declares it as a
// 16-byte DECIMAL, which IPropertyStore::GetValue would overrun.
PropVariant :: struct {
	vt:        u16,
	reserved1: u16,
	reserved2: u16,
	reserved3: u16,
	using value: struct #raw_union {
		pwszVal: win.wstring,
		ulVal:   u32,
		padding: [2]u64,
	},
}
#assert(size_of(PropVariant) == 24)

IAudioCaptureClient :: struct #raw_union {
	#subtype iunknown: win.IUnknown,
	using vtable: ^IAudioCaptureClient_VTable,
}
IAudioCaptureClient_VTable :: struct {
	using iunknown_vtable: win.IUnknown_VTable,
	GetBuffer: proc "system" (
		This: ^IAudioCaptureClient,
		ppData: ^[^]u8,
		pNumFramesToRead: ^u32,
		pdwFlags: ^u32,
		pu64DevicePosition: ^u64,
		pu64QPCPosition: ^u64,
	) -> win.HRESULT,
	ReleaseBuffer: proc "system" (This: ^IAudioCaptureClient, NumFramesRead: u32) -> win.HRESULT,
	GetNextPacketSize: proc "system" (
		This: ^IAudioCaptureClient,
		pNumFramesInNextPacket: ^u32,
	) -> win.HRESULT,
}

AUDIO_EFFECT :: struct {
	id:          win.GUID,
	canSetState: win.BOOL,
	state:       u32,
}

IAudioEffectsManager :: struct #raw_union {
	#subtype iunknown: win.IUnknown,
	using vtable: ^IAudioEffectsManager_VTable,
}
IAudioEffectsManager_VTable :: struct {
	using iunknown_vtable: win.IUnknown_VTable,
	RegisterAudioEffectsChangedNotificationCallback: proc "system" (
		This: ^IAudioEffectsManager,
		client: rawptr,
	) -> win.HRESULT,
	UnregisterAudioEffectsChangedNotificationCallback: proc "system" (
		This: ^IAudioEffectsManager,
		client: rawptr,
	) -> win.HRESULT,
	GetAudioEffects: proc "system" (
		This: ^IAudioEffectsManager,
		effects: ^[^]AUDIO_EFFECT,
		numEffects: ^u32,
	) -> win.HRESULT,
	SetAudioEffectState: proc "system" (
		This: ^IAudioEffectsManager,
		effectId: win.GUID,
		state: u32,
	) -> win.HRESULT,
}

IAcousticEchoCancellationControl :: struct #raw_union {
	#subtype iunknown: win.IUnknown,
	using vtable: ^IAcousticEchoCancellationControl_VTable,
}
IAcousticEchoCancellationControl_VTable :: struct {
	using iunknown_vtable: win.IUnknown_VTable,
	SetEchoCancellationRenderEndpoint: proc "system" (
		This: ^IAcousticEchoCancellationControl,
		endpointId: win.LPCWSTR,
	) -> win.HRESULT,
}

failed :: #force_inline proc(hr: win.HRESULT) -> bool {
	return hr < 0
}

hrText :: proc(hr: win.HRESULT) -> string {
	return formatHresult(u32(hr))
}

release :: proc(object: ^win.IUnknown) {
	if object != nil {
		object->Release()
	}
}

// ── Endpoints ─────────────────────────────────────────────────────

Endpoint :: struct {
	id:            string,
	name:          string,
	state:         u32,
	// -1 when the property is missing, else the PKEY_AudioEndpoint_Disable_SysFx value.
	sysFxDisabled: int,
}

wideToString :: proc(text: win.wstring) -> string {
	if text == nil {
		return ""
	}
	result, _ := win.wstring_to_utf8(text, -1, context.allocator)
	return result
}

deviceID :: proc(device: ^wasapi.IMMDevice) -> string {
	raw: win.LPWSTR
	if failed(device->GetId(&raw)) {
		return ""
	}
	defer win.CoTaskMemFree(rawptr(raw))
	return wideToString(win.wstring(raw))
}

describeDevice :: proc(device: ^wasapi.IMMDevice) -> Endpoint {
	endpoint := Endpoint {
		id            = deviceID(device),
		sysFxDisabled = -1,
	}
	_ = device->GetState(&endpoint.state)
	store: ^win.IPropertyStore
	if failed(device->OpenPropertyStore(STGM_READ, cast([^]^win.IPropertyStore)&store)) {
		return endpoint
	}
	defer release(store)
	value: PropVariant
	if !failed(store->GetValue(&PKEY_Device_FriendlyName, cast(^win.PROPVARIANT)&value)) {
		if value.vt == VT_LPWSTR {
			endpoint.name = wideToString(value.pwszVal)
		}
		win.PropVariantClear(cast(^win.PROPVARIANT)&value)
	}
	value = {}
	if !failed(store->GetValue(&PKEY_AudioEndpoint_Disable_SysFx, cast(^win.PROPVARIANT)&value)) {
		if value.vt == VT_UI4 {
			endpoint.sysFxDisabled = int(value.ulVal)
		}
		win.PropVariantClear(cast(^win.PROPVARIANT)&value)
	}
	return endpoint
}

stateName :: proc(state: u32) -> string {
	switch state {
	case 0x1:
		return "active"
	case 0x2:
		return "disabled"
	case 0x4:
		return "not present"
	case 0x8:
		return "unplugged"
	}
	return "unknown"
}

listEndpoints :: proc(
	enumerator: ^wasapi.IMMDeviceEnumerator,
	flow: wasapi.EDataFlow,
) -> (
	endpoints: [dynamic]Endpoint,
	hr: win.HRESULT,
) {
	collectionPointer: [^]wasapi.IMMDeviceCollection
	hr = enumerator->EnumAudioEndpoints(flow, DEVICE_STATEMASK_ALL, &collectionPointer)
	if failed(hr) {
		return
	}
	collection := cast(^wasapi.IMMDeviceCollection)collectionPointer
	defer release(collection)
	count: win.UINT
	_ = collection->GetCount(&count)
	for index in 0 ..< count {
		device: ^wasapi.IMMDevice
		if failed(collection->Item(index, &device)) {
			continue
		}
		append(&endpoints, describeDevice(device))
		release(device)
	}
	return
}

defaultEndpointID :: proc(
	enumerator: ^wasapi.IMMDeviceEnumerator,
	flow: wasapi.EDataFlow,
	role: wasapi.ERole,
) -> (
	string,
	win.HRESULT,
) {
	device: ^wasapi.IMMDevice
	hr := enumerator->GetDefaultAudioEndpoint(flow, role, &device)
	if failed(hr) {
		return "", hr
	}
	defer release(device)
	return deviceID(device), hr
}

printEndpoints :: proc(
	label: string,
	endpoints: []Endpoint,
	consoleID, communicationsID: string,
) {
	fmt.printfln("%s endpoints: %d", label, len(endpoints))
	for endpoint in endpoints {
		marks := ""
		if endpoint.id == consoleID && endpoint.id == communicationsID {
			marks = " [default console + communications]"
		} else if endpoint.id == consoleID {
			marks = " [default console]"
		} else if endpoint.id == communicationsID {
			marks = " [default communications]"
		}
		sysfx := "unknown"
		if endpoint.sysFxDisabled == 0 {
			sysfx = "on"
		} else if endpoint.sysFxDisabled > 0 {
			sysfx = "off"
		}
		fmt.printfln(
			"  %q (%s, enhancements %s)%s\n    id %s",
			endpoint.name,
			stateName(endpoint.state),
			sysfx,
			marks,
			endpoint.id,
		)
	}
}

// findEndpoint matches an endpoint ID exactly or an active endpoint's friendly name without
// case (SDL names devices by PKEY_Device_FriendlyName too).
findEndpoint :: proc(endpoints: []Endpoint, wanted: string) -> (Endpoint, bool) {
	for endpoint in endpoints {
		if endpoint.id == wanted {
			return endpoint, true
		}
	}
	for endpoint in endpoints {
		if endpoint.state == DEVICE_STATE_ACTIVE && strings.equal_fold(endpoint.name, wanted) {
			return endpoint, true
		}
	}
	return {}, false
}

// ── Device change notifications ───────────────────────────────────

// DeviceEvents implements IMMNotificationClient; its vtable pointer comes first, as COM
// expects. The callbacks run on a Windows thread and only bump counters.
DeviceEvents :: struct {
	vtable:          ^wasapi.IMMNotificationClient_VTable,
	stateChanged:    i32,
	added:           i32,
	removed:         i32,
	defaultChanged:  i32,
	propertyChanged: i32,
	captureDefault:  i32,
}

deviceEventsVTable := wasapi.IMMNotificationClient_VTable {
	QueryInterface = proc "system" (
		This: ^win.IUnknown,
		riid: win.REFIID,
		ppvObject: ^rawptr,
	) -> win.HRESULT {
		if riid^ == win.IUnknown_UUID^ || riid^ == IID_IMMNotificationClient {
			ppvObject^ = This
			return win.S_OK
		}
		ppvObject^ = nil
		return E_NOINTERFACE
	},
	AddRef = proc "system" (This: ^win.IUnknown) -> win.ULONG {return 1},
	Release = proc "system" (This: ^win.IUnknown) -> win.ULONG {return 1},
	OnDeviceStateChanged = proc "system" (
		This: ^wasapi.IMMNotificationClient,
		pwstrDeviceId: win.LPCWSTR,
		dwNewState: win.DWORD,
	) -> win.HRESULT {
		sync.atomic_add(&(cast(^DeviceEvents)This).stateChanged, 1)
		return win.S_OK
	},
	OnDeviceAdded = proc "system" (
		This: ^wasapi.IMMNotificationClient,
		pwstrDeviceId: win.LPCWSTR,
	) -> win.HRESULT {
		sync.atomic_add(&(cast(^DeviceEvents)This).added, 1)
		return win.S_OK
	},
	OnDeviceRemoved = proc "system" (
		This: ^wasapi.IMMNotificationClient,
		pwstrDeviceId: win.LPCWSTR,
	) -> win.HRESULT {
		sync.atomic_add(&(cast(^DeviceEvents)This).removed, 1)
		return win.S_OK
	},
	OnDefaultDeviceChanged = proc "system" (
		This: ^wasapi.IMMNotificationClient,
		flow: wasapi.EDataFlow,
		role: wasapi.ERole,
		pwstrDefaultDeviceId: win.LPCWSTR,
	) -> win.HRESULT {
		events := cast(^DeviceEvents)This
		sync.atomic_add(&events.defaultChanged, 1)
		if flow == .Capture {
			sync.atomic_add(&events.captureDefault, 1)
		}
		return win.S_OK
	},
	OnPropertyValueChanged = proc "system" (
		This: ^wasapi.IMMNotificationClient,
		pwstrDeviceId: win.LPCWSTR,
		key: win.PROPERTYKEY,
	) -> win.HRESULT {
		sync.atomic_add(&(cast(^DeviceEvents)This).propertyChanged, 1)
		return win.S_OK
	},
}

// ── One capture stream ────────────────────────────────────────────

StreamSetup :: struct {
	label:       string,
	category:    StreamCategory,
	raw:         bool,
	autoconvert: bool,
}

Stream :: struct {
	client:       ^wasapi.IAudioClient,
	mixFormat:    ^wasapi.WAVEFORMATEX,
	sampleFormat: SampleFormat,
	channels:     int,
	rate:         int,
}

streamClose :: proc(stream: ^Stream) {
	release(stream.client)
	if stream.mixFormat != nil {
		win.CoTaskMemFree(stream.mixFormat)
	}
	stream^ = {}
}

describeFormat :: proc(format: ^wasapi.WAVEFORMATEX) -> (string, SampleFormat) {
	sampleFormat := SampleFormat.Unsupported
	kind := fmt.tprint(format.wFormatTag)
	validBits := int(format.wBitsPerSample)
	mask: u32
	#partial switch format.wFormatTag {
	case .IEEE_FLOAT:
		if format.wBitsPerSample == 32 {
			sampleFormat = .Float32
		}
	case WAVE_FORMAT_PCM:
		if format.wBitsPerSample == 16 {
			sampleFormat = .Int16
		}
	case .EXTENSIBLE:
		extensible := cast(^wasapi.WAVEFORMATEXTENSIBLE)format
		validBits = int(extensible.wValidBitsPerSample)
		mask = transmute(u32)extensible.dwChannelMask
		if extensible.SubFormat == wasapi.KSDATAFORMAT_SUBTYPE_IEEE_FLOAT {
			kind = "EXTENSIBLE float"
			if format.wBitsPerSample == 32 {
				sampleFormat = .Float32
			}
		} else if extensible.SubFormat == KSDATAFORMAT_SUBTYPE_PCM {
			kind = "EXTENSIBLE PCM"
			switch format.wBitsPerSample {
			case 16:
				sampleFormat = .Int16
			case 32:
				sampleFormat = .Int32
			}
		} else {
			kind = fmt.tprintf("EXTENSIBLE %s", formatGuid(transmute(Guid)extensible.SubFormat))
		}
	}
	return fmt.tprintf(
		"%s, %d ch, %d Hz, %d bits (%d valid), block %d, channel mask 0x%x",
		kind,
		format.nChannels,
		format.nSamplesPerSec,
		format.wBitsPerSample,
		validBits,
		format.nBlockAlign,
		mask,
	), sampleFormat
}

monoFloatFormat :: proc() -> wasapi.WAVEFORMATEXTENSIBLE {
	format: wasapi.WAVEFORMATEXTENSIBLE
	format.Format = {
		wFormatTag      = .EXTENSIBLE,
		nChannels       = 1,
		nSamplesPerSec  = SAMPLE_RATE,
		nAvgBytesPerSec = SAMPLE_RATE * 4,
		nBlockAlign     = 4,
		wBitsPerSample  = 32,
		cbSize          = size_of(wasapi.WAVEFORMATEXTENSIBLE) - size_of(wasapi.WAVEFORMATEX),
	}
	format.wValidBitsPerSample = 32
	format.dwChannelMask = {.FRONT_CENTER}
	format.SubFormat = wasapi.KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
	return format
}

// streamOpen activates an IAudioClient on the endpoint, sets the category, initialises a
// shared, event-driven stream and prints what Windows reports on the way. Output lines are
// indented under the caller's heading.
streamOpen :: proc(
	device: ^wasapi.IMMDevice,
	setup: StreamSetup,
	event: win.HANDLE,
) -> (
	stream: Stream,
	ok: bool,
) {
	hr := device->Activate(
		wasapi.IID_IAudioClient,
		win.CLSCTX_ALL,
		nil,
		cast([^]rawptr)&stream.client,
	)
	if failed(hr) {
		fmt.printfln("  Activate(IAudioClient): %s", hrText(hr))
		return
	}
	client2: ^wasapi.IAudioClient2
	hr = stream.client->QueryInterface(&IID_IAudioClient2, cast(^rawptr)&client2)
	if failed(hr) {
		fmt.printfln("  IAudioClient2: %s (no categories before Windows 8)", hrText(hr))
	} else {
		properties := wasapi.AudioClientProperties {
			cbSize    = size_of(wasapi.AudioClientProperties),
			eCategory = wasapi.AUDIO_STREAM_CATEGORY(setup.category),
		}
		if setup.raw {
			properties.Options = {.RAW}
		}
		hr = client2->SetClientProperties(&properties)
		fmt.printfln(
			"  SetClientProperties(category %v%s): %s",
			setup.category,
			setup.raw ? ", RAW" : "",
			hrText(hr),
		)
		release(client2)
	}

	hr = stream.client->GetMixFormat(&stream.mixFormat)
	if failed(hr) {
		fmt.printfln("  GetMixFormat: %s", hrText(hr))
		return
	}
	mixText, mixSampleFormat := describeFormat(stream.mixFormat)
	fmt.printfln("  mix format: %s", mixText)

	defaultPeriod, minimumPeriod: wasapi.REFERENCE_TIME
	if !failed(stream.client->GetDevicePeriod(&defaultPeriod, &minimumPeriod)) {
		fmt.printfln(
			"  device period: default %.2f ms, minimum %.2f ms",
			f64(defaultPeriod) / REFTIMES_PER_MS,
			f64(minimumPeriod) / REFTIMES_PER_MS,
		)
	}
	client3: ^wasapi.IAudioClient3
	if !failed(stream.client->QueryInterface(&IID_IAudioClient3, cast(^rawptr)&client3)) {
		defaultFrames, fundamentalFrames, minimumFrames, maximumFrames: u32
		hr = client3->GetSharedModeEnginePeriod(
			stream.mixFormat,
			&defaultFrames,
			&fundamentalFrames,
			&minimumFrames,
			&maximumFrames,
		)
		if !failed(hr) {
			fmt.printfln(
				"  shared engine period (frames at %d Hz): default %d, fundamental %d, " +
				"min %d, max %d",
				stream.mixFormat.nSamplesPerSec,
				defaultFrames,
				fundamentalFrames,
				minimumFrames,
				maximumFrames,
			)
		}
		release(client3)
	}

	wanted := monoFloatFormat()
	closest: ^wasapi.WAVEFORMATEX
	hr = stream.client->IsFormatSupported(.SHARED, &wanted.Format, &closest)
	fmt.printfln(
		"  48 kHz mono float natively: %s",
		hr == win.S_OK ? "yes" : fmt.tprintf("no (%s), AUTOCONVERTPCM needed", hrText(hr)),
	)
	if closest != nil {
		win.CoTaskMemFree(closest)
	}

	flags := u32(wasapi.AUDCLNT_FLAG.STREAM_EVENTCALLBACK)
	format := &wanted.Format
	if setup.autoconvert {
		flags |= u32(wasapi.AUDCLNT_FLAG.STREAM_AUTOCONVERTPCM)
		flags |= u32(wasapi.AUDCLNT_FLAG.STREAM_SRC_DEFAULT_QUALITY)
		stream.sampleFormat = .Float32
		stream.channels = 1
		stream.rate = SAMPLE_RATE
	} else {
		format = stream.mixFormat
		stream.sampleFormat = mixSampleFormat
		stream.channels = int(stream.mixFormat.nChannels)
		stream.rate = int(stream.mixFormat.nSamplesPerSec)
		if stream.sampleFormat == .Unsupported {
			fmt.println("  the tool cannot convert this mix format; use AUTOCONVERTPCM")
			return
		}
	}
	hr = stream.client->Initialize(.SHARED, flags, 0, 0, format, nil)
	fmt.printfln(
		"  Initialize(shared, event%s): %s",
		setup.autoconvert \
		? ", AUTOCONVERTPCM + SRC_DEFAULT_QUALITY, 48 kHz mono float" \
		: ", mix format",
		hrText(hr),
	)
	if failed(hr) {
		return
	}
	bufferFrames: u32
	latency: wasapi.REFERENCE_TIME
	_ = stream.client->GetBufferSize(&bufferFrames)
	_ = stream.client->GetStreamLatency(&latency)
	fmt.printfln(
		"  buffer %d frames (%.1f ms), stream latency %.2f ms",
		bufferFrames,
		f64(bufferFrames) * 1000 / f64(stream.rate),
		f64(latency) / REFTIMES_PER_MS,
	)
	hr = stream.client->SetEventHandle(event)
	if failed(hr) {
		fmt.printfln("  SetEventHandle: %s", hrText(hr))
		return
	}
	ok = true
	return
}

// streamEffects lists the stream's effects (IAudioEffectsManager, Windows 11 build 22000+;
// GetService needs an initialised stream).
streamEffects :: proc(stream: ^Stream) -> (effects: [dynamic]Effect, known: bool) {
	manager: ^IAudioEffectsManager
	hr := stream.client->GetService(&IID_IAudioEffectsManager, cast(^rawptr)&manager)
	if failed(hr) {
		fmt.printfln("  IAudioEffectsManager: %s (Windows 11 build 22000 or later)", hrText(hr))
		return
	}
	defer release(manager)
	list: [^]AUDIO_EFFECT
	count: u32
	hr = manager->GetAudioEffects(&list, &count)
	if failed(hr) {
		fmt.printfln("  GetAudioEffects: %s", hrText(hr))
		return
	}
	defer win.CoTaskMemFree(list)
	known = true
	fmt.printfln("  effects: %d", count)
	for index in 0 ..< int(count) {
		entry := list[index]
		effect := Effect {
			id          = transmute(Guid)entry.id,
			canSetState = entry.canSetState != false,
			on          = entry.state != 0,
		}
		append(&effects, effect)
		fmt.printfln(
			"    %v %s: %s%s",
			effectKind(effect.id),
			formatGuid(effect.id),
			effect.on ? "on" : "off",
			effect.canSetState ? ", app may change it" : "",
		)
	}
	return
}

// streamEchoReference asks for IAcousticEchoCancellationControl (build 22621+) and points the
// echo reference at `renderID`, or at Windows' own choice (NULL) when it is empty. It returns
// false when the stream offers no such control.
streamEchoReference :: proc(stream: ^Stream, renderID: string) -> bool {
	control: ^IAcousticEchoCancellationControl
	hr := stream.client->GetService(
		&IID_IAcousticEchoCancellationControl,
		cast(^rawptr)&control,
	)
	if failed(hr) {
		fmt.printfln(
			"  IAcousticEchoCancellationControl: %s (no AEC reference control here)",
			hrText(hr),
		)
		return false
	}
	defer release(control)
	if renderID == "" {
		hr = control->SetEchoCancellationRenderEndpoint(nil)
		fmt.printfln("  SetEchoCancellationRenderEndpoint(NULL, Windows' choice): %s", hrText(hr))
	} else {
		wide := win.utf8_to_wstring(renderID, context.temp_allocator)
		hr = control->SetEchoCancellationRenderEndpoint(wide)
		fmt.printfln("  SetEchoCancellationRenderEndpoint(render endpoint): %s", hrText(hr))
	}
	return true
}

// TonePlayer plays a sine through SDL's playback device, as the client does.
TonePlayer :: struct {
	stream:    ^SDL.AudioStream,
	phase:     f64,
	step:      f64,
	amplitude: f32,
	buffer:    [SAMPLE_RATE / 50]f32,
}

tonePlayerOpen :: proc(player: ^TonePlayer, options: Options, renderName: string) -> bool {
	_ = SDL.SetHint(SDL.HINT_AUDIO_DEVICE_STREAM_ROLE, "Communications")
	_ = SDL.SetHint(SDL.HINT_AUDIO_DEVICE_STREAM_NAME, "wasapi-probe tone")
	if !SDL.InitSubSystem({.AUDIO}) {
		fmt.printfln("SDL audio: %s", SDL.GetError())
		return false
	}
	deviceID := SDL.AUDIO_DEVICE_DEFAULT_PLAYBACK
	if options.render != "" {
		count: i32
		devices := SDL.GetAudioPlaybackDevices(&count)
		if devices != nil {
			for index in 0 ..< int(count) {
				if string(SDL.GetAudioDeviceName(devices[index])) == renderName {
					deviceID = devices[index]
				}
			}
			SDL.free(devices)
		}
	}
	spec := SDL.AudioSpec {
		format   = .F32,
		channels = 1,
		freq     = SAMPLE_RATE,
	}
	player.stream = SDL.OpenAudioDeviceStream(deviceID, &spec, nil, nil)
	if player == nil || player.stream == nil {
		fmt.printfln("SDL playback: %s", SDL.GetError())
		return false
	}
	device := SDL.GetAudioStreamDevice(player.stream)
	fmt.printfln("SDL playback device: %q", SDL.GetAudioDeviceName(device))
	player.step = 2 * math.PI * options.toneHz / SAMPLE_RATE
	player.amplitude = f32(options.toneAmplitude)
	return SDL.ResumeAudioStreamDevice(player.stream)
}

// tonePlayerFeed keeps about 100 ms queued.
tonePlayerFeed :: proc(player: ^TonePlayer) {
	if player == nil || player.stream == nil {
		return
	}
	for SDL.GetAudioStreamQueued(player.stream) < SAMPLE_RATE / 10 * size_of(f32) {
		for &sample in player.buffer {
			sample = player.amplitude * f32(math.sin(player.phase))
			player.phase = math.mod(player.phase + player.step, 2 * math.PI)
		}
		_ = SDL.PutAudioStreamData(player.stream, &player.buffer, size_of(player.buffer))
	}
}

tonePlayerClose :: proc(player: ^TonePlayer) {
	if player.stream != nil {
		SDL.DestroyAudioStream(player.stream)
		player.stream = nil
	}
	SDL.QuitSubSystem({.AUDIO})
}

// streamCapture reads the started stream for `seconds`, converting to mono float, writing to
// `out` when it is set and feeding the tone player.
streamCapture :: proc(
	stream: ^Stream,
	event: win.HANDLE,
	seconds: f64,
	out: ^os.File,
	player: ^TonePlayer,
) -> CaptureStats {
	stats: CaptureStats
	capture: ^IAudioCaptureClient
	hr := stream.client->GetService(&IID_IAudioCaptureClient, cast(^rawptr)&capture)
	if failed(hr) {
		fmt.printfln("  GetService(IAudioCaptureClient): %s", hrText(hr))
		stats.stopError = u32(hr)
		return stats
	}
	defer release(capture)
	mono := make([dynamic]f32, SAMPLE_RATE)
	defer delete(mono)
	hr = stream.client->Start()
	if failed(hr) {
		fmt.printfln("  Start: %s", hrText(hr))
		stats.stopError = u32(hr)
		return stats
	}
	defer stream.client->Stop()
	start := time.tick_now()
	last := start
	first := true
	duration := time.Duration(seconds * f64(time.Second))
	loop: for time.tick_since(start) < duration {
		tonePlayerFeed(player)
		if win.WaitForSingleObject(event, 200) == win.WAIT_TIMEOUT {
			stats.eventTimeouts += 1
			continue
		}
		now := time.tick_now()
		gap := time.duration_milliseconds(time.tick_diff(last, now))
		stats.maxEventGapMs = max(stats.maxEventGapMs, gap)
		last = now
		for {
			frames: u32
			hr = capture->GetNextPacketSize(&frames)
			if failed(hr) {
				stats.stopError = u32(hr)
				break loop
			}
			if frames == 0 {
				break
			}
			data: [^]u8
			flags: u32
			hr = capture->GetBuffer(&data, &frames, &flags, nil, nil)
			if failed(hr) {
				stats.stopError = u32(hr)
				break loop
			}
			if hr == AUDCLNT_S_BUFFER_EMPTY {
				break
			}
			if first {
				stats.firstPacketMs = time.duration_milliseconds(time.tick_since(start))
				first = false
			}
			if int(frames) > len(mono) {
				resize(&mono, int(frames))
			}
			samples := mono[:frames]
			if flags & AUDCLNT_BUFFERFLAGS_SILENT != 0 {
				mem.zero_slice(samples)
			} else {
				bytes := int(frames) * stream.channels * sampleFormatBytes(stream.sampleFormat)
				_ = downmixToMono(
					samples,
					data[:bytes],
					int(frames),
					stream.channels,
					stream.sampleFormat,
				)
			}
			captureStatsAddPacket(&stats, int(frames), flags)
			captureStatsAddLevels(&stats, samples)
			if out != nil {
				_, _ = os.write(out, mem.slice_to_bytes(samples))
			}
			_ = capture->ReleaseBuffer(frames)
		}
	}
	return stats
}

// ── The run ───────────────────────────────────────────────────────

osBuild :: proc() -> (major, minor, build: u32) {
	info := win.OSVERSIONINFOEXW {
		dwOSVersionInfoSize = size_of(win.OSVERSIONINFOEXW),
	}
	_ = win.RtlGetVersion(&info)
	return info.dwMajorVersion, info.dwMinorVersion, info.dwBuildNumber
}

PROBE_SETUPS := [?]StreamSetup {
	{label = "Other (what SDL 3.4.18 sets today)", category = .Other},
	{label = "Other + RAW (SDL_HINT_AUDIO_DEVICE_RAW_STREAM)", category = .Other, raw = true},
	{label = "Communications", category = .Communications},
	{label = "Communications + RAW", category = .Communications, raw = true},
	{label = "Speech", category = .Speech},
	{
		label = "GameChat (the category SDL's comment says broke USB microphones)",
		category = .GameChat,
	},
}

run :: proc(options: Options) -> int {
	context.allocator = context.temp_allocator
	major, minor, build := osBuild()
	fmt.printfln("os: Windows %d.%d build %d", major, minor, build)
	fmt.printfln(
		"  IAudioEffectsManager needs build 22000, IAcousticEchoCancellationControl 22621: %s, %s",
		build >= 22000 ? "yes" : "no",
		build >= 22621 ? "yes" : "no",
	)

	hr := win.CoInitializeEx(nil, .MULTITHREADED)
	if failed(hr) {
		fmt.printfln("CoInitializeEx: %s", hrText(hr))
		return EXIT_FAILED
	}
	defer win.CoUninitialize()
	enumerator: ^wasapi.IMMDeviceEnumerator
	hr = win.CoCreateInstance(
		wasapi.CLSID_MMDeviceEnumerator,
		nil,
		win.CLSCTX_ALL,
		wasapi.IID_IMMDeviceEnumerator,
		cast(^rawptr)&enumerator,
	)
	if failed(hr) {
		fmt.printfln("CoCreateInstance(MMDeviceEnumerator): %s", hrText(hr))
		return EXIT_FAILED
	}
	defer release(enumerator)

	captures, captureHR := listEndpoints(enumerator, .Capture)
	renders, renderHR := listEndpoints(enumerator, .Render)
	if failed(captureHR) || failed(renderHR) {
		fmt.printfln(
			"EnumAudioEndpoints: capture %s, render %s",
			hrText(captureHR),
			hrText(renderHR),
		)
	}
	captureConsole, captureConsoleHR := defaultEndpointID(enumerator, .Capture, .Console)
	captureComms, _ := defaultEndpointID(enumerator, .Capture, .Communications)
	renderConsole, renderConsoleHR := defaultEndpointID(enumerator, .Render, .Console)
	renderComms, _ := defaultEndpointID(enumerator, .Render, .Communications)
	printEndpoints("capture", captures[:], captureConsole, captureComms)
	printEndpoints("render", renders[:], renderConsole, renderComms)
	if failed(captureConsoleHR) {
		fmt.printfln("default capture endpoint: %s", hrText(captureConsoleHR))
	}
	if failed(renderConsoleHR) {
		fmt.printfln("default render endpoint: %s", hrText(renderConsoleHR))
	}
	if options.list {
		return EXIT_OK
	}

	// The capture endpoint.
	captureID := options.defaultRole == .Communications ? captureComms : captureConsole
	if options.device != "" {
		endpoint, found := findEndpoint(captures[:], options.device)
		if !found {
			fmt.printfln("no capture endpoint matches %q", options.device)
			return EXIT_FAILED
		}
		captureID = endpoint.id
	}
	if captureID == "" {
		fmt.println("no capture endpoint: nothing to probe (this machine has no microphone)")
		return EXIT_FAILED
	}
	// The echo reference: SDL's playback endpoint.
	renderID := renderConsole
	renderName := ""
	if options.render != "" {
		endpoint, found := findEndpoint(renders[:], options.render)
		if !found {
			fmt.printfln("no render endpoint matches %q", options.render)
			return EXIT_FAILED
		}
		renderID = endpoint.id
		renderName = endpoint.name
	}
	device: ^wasapi.IMMDevice
	hr = enumerator->GetDevice(win.utf8_to_wstring(captureID), &device)
	if failed(hr) {
		fmt.printfln("GetDevice(capture): %s", hrText(hr))
		return EXIT_FAILED
	}
	defer release(device)
	fmt.printfln("capture endpoint: %s", captureID)
	fmt.printfln("echo reference (render) endpoint: %s", renderID == "" ? "none" : renderID)

	event := win.CreateEventW(nil, false, false, nil)
	defer win.CloseHandle(event)

	// The comparison: one stream per category, each with a short capture.
	for setup in PROBE_SETUPS {
		fmt.printfln("probe %s:", setup.label)
		probeSetup := setup
		probeSetup.autoconvert = true
		stream, opened := streamOpen(device, probeSetup, event)
		if opened {
			effects, known := streamEffects(&stream)
			advice := processingAdvice(effects[:], known)
			fmt.printfln("  processing: %s", processingAdviceText(advice))
			if streamEchoReference(&stream, renderID) && renderID != "" {
				_ = streamEchoReference(&stream, "")
			}
			if options.probeSeconds > 0 {
				stats := streamCapture(&stream, event, options.probeSeconds, nil, nil)
				fmt.printfln(
					"  capture: %s",
					captureStatsSummary(stats, stream.rate, options.probeSeconds),
				)
				if stats.stopError != 0 {
					fmt.printfln("  stopped by %s", formatHresult(stats.stopError))
				}
			}
		}
		streamClose(&stream)
	}
	if options.seconds == 0 {
		return EXIT_OK
	}

	// The main capture, with device notifications and the optional tone.
	fmt.printfln(
		"main capture: category %v%s, %s, %.1f s",
		options.category,
		options.raw ? " + RAW" : "",
		options.autoconvert ? "AUTOCONVERTPCM" : "mix format",
		options.seconds,
	)
	events := DeviceEvents {
		vtable = &deviceEventsVTable,
	}
	notifyHR := enumerator->RegisterEndpointNotificationCallback(
		cast(^wasapi.IMMNotificationClient)&events,
	)
	if failed(notifyHR) {
		fmt.printfln("  RegisterEndpointNotificationCallback: %s", hrText(notifyHR))
	}
	defer if !failed(notifyHR) {
		_ = enumerator->UnregisterEndpointNotificationCallback(
			cast(^wasapi.IMMNotificationClient)&events,
		)
	}
	stream, opened := streamOpen(
		device,
		{
			label = "main",
			category = options.category,
			raw = options.raw,
			autoconvert = options.autoconvert,
		},
		event,
	)
	defer streamClose(&stream)
	if !opened {
		return EXIT_FAILED
	}
	effects, known := streamEffects(&stream)
	fmt.printfln("  processing: %s", processingAdviceText(processingAdvice(effects[:], known)))
	_ = streamEchoReference(&stream, options.echoReference == .Windows ? "" : renderID)
	out: ^os.File
	if options.outPath != "" {
		file, err := os.create(options.outPath)
		if err != nil {
			fmt.printfln("cannot create %s: %v", options.outPath, err)
			return EXIT_FAILED
		}
		out = file
	}
	defer if out != nil {
		os.close(out)
	}
	player: TonePlayer
	if options.toneHz > 0 {
		if !tonePlayerOpen(&player, options, renderName) {
			tonePlayerClose(&player)
			return EXIT_FAILED
		}
	}
	stats := streamCapture(&stream, event, options.seconds, out, &player)
	if options.toneHz > 0 {
		tonePlayerClose(&player)
	}
	fmt.printfln("  capture: %s", captureStatsSummary(stats, stream.rate, options.seconds))
	if stats.stopError != 0 {
		fmt.printfln("  stopped by %s", formatHresult(stats.stopError))
		if stats.stopError == AUDCLNT_E_DEVICE_INVALIDATED {
			fmt.println("  (the endpoint went away; a real backend reopens the default here)")
		}
	}
	fmt.printfln(
		"  device events: state %d, added %d, removed %d, default changed %d (capture %d), " +
		"property %d",
		sync.atomic_load(&events.stateChanged),
		sync.atomic_load(&events.added),
		sync.atomic_load(&events.removed),
		sync.atomic_load(&events.defaultChanged),
		sync.atomic_load(&events.captureDefault),
		sync.atomic_load(&events.propertyChanged),
	)
	if out != nil {
		fmt.printfln(
			"  wrote %s: raw F32LE mono %d Hz (check with dev/tools/voice-check)",
			options.outPath,
			stream.rate,
		)
	}
	return stats.stopError == 0 ? EXIT_OK : EXIT_FAILED
}
