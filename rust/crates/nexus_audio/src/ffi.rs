//! Binding minimo do libmpv (client.h), carregado em runtime com libloading.

use std::ffi::{CStr, CString, c_char, c_double, c_int, c_void};

use libloading::Library;

const MPV_FORMAT_DOUBLE: c_int = 5;
const MPV_EVENT_SHUTDOWN: c_int = 1;
const MPV_EVENT_END_FILE: c_int = 7;
const MPV_EVENT_FILE_LOADED: c_int = 8;

pub const END_FILE_REASON_EOF: c_int = 0;
pub const END_FILE_REASON_ERROR: c_int = 4;

#[repr(C)]
struct MpvEvent {
    event_id: c_int,
    error: c_int,
    reply_userdata: u64,
    data: *mut c_void,
}

// Prefixo de mpv_event_end_file (os primeiros campos nunca mudam).
#[repr(C)]
struct MpvEventEndFile {
    reason: c_int,
    error: c_int,
}

type CreateFn = unsafe extern "C" fn() -> *mut c_void;
type InitializeFn = unsafe extern "C" fn(*mut c_void) -> c_int;
type SetStringFn = unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char) -> c_int;
type CommandFn = unsafe extern "C" fn(*mut c_void, *mut *const c_char) -> c_int;
type GetPropertyFn =
    unsafe extern "C" fn(*mut c_void, *const c_char, c_int, *mut c_void) -> c_int;
type WaitEventFn = unsafe extern "C" fn(*mut c_void, c_double) -> *mut MpvEvent;
type TerminateDestroyFn = unsafe extern "C" fn(*mut c_void);
type ErrorStringFn = unsafe extern "C" fn(c_int) -> *const c_char;

struct MpvApi {
    create: CreateFn,
    initialize: InitializeFn,
    set_option_string: SetStringFn,
    set_property_string: SetStringFn,
    command: CommandFn,
    get_property: GetPropertyFn,
    wait_event: WaitEventFn,
    terminate_destroy: TerminateDestroyFn,
    error_string: ErrorStringFn,
    // Precisa viver mais que os ponteiros de funcao acima.
    _lib: Library,
}

const CANDIDATES: &[&str] = &[
    "libmpv.so",
    "libmpv.so.2",
    "libmpv-2.dll",
    "mpv-2.dll",
    "libmpv.dylib",
];

fn open_library() -> Result<Library, String> {
    if let Ok(path) = std::env::var("NEXUS_MPV_LIB") {
        return unsafe { Library::new(&path) }.map_err(|e| format!("{path}: {e}"));
    }

    let mut last = String::new();
    for name in CANDIDATES {
        match unsafe { Library::new(name) } {
            Ok(lib) => return Ok(lib),
            Err(e) => last = format!("{name}: {e}"),
        }
    }
    Err(format!("could not load libmpv ({last})"))
}

fn sym<T: Copy>(lib: &Library, name: &'static str) -> Result<T, String> {
    let mut bytes = name.as_bytes().to_vec();
    bytes.push(0);
    let symbol = unsafe { lib.get::<T>(&bytes) }.map_err(|e| format!("symbol {name}: {e}"))?;
    Ok(*symbol)
}

impl MpvApi {
    fn load() -> Result<Self, String> {
        let lib = open_library()?;
        Ok(Self {
            create: sym(&lib, "mpv_create")?,
            initialize: sym(&lib, "mpv_initialize")?,
            set_option_string: sym(&lib, "mpv_set_option_string")?,
            set_property_string: sym(&lib, "mpv_set_property_string")?,
            command: sym(&lib, "mpv_command")?,
            get_property: sym(&lib, "mpv_get_property")?,
            wait_event: sym(&lib, "mpv_wait_event")?,
            terminate_destroy: sym(&lib, "mpv_terminate_destroy")?,
            error_string: sym(&lib, "mpv_error_string")?,
            _lib: lib,
        })
    }
}

pub enum RawEvent {
    None,
    Shutdown,
    FileLoaded,
    EndFile { reason: i32, error: i32 },
    Other,
}

pub struct MpvHandle {
    api: MpvApi,
    ctx: *mut c_void,
}

// A API cliente do mpv e thread-safe segundo a documentacao do client.h.
unsafe impl Send for MpvHandle {}
unsafe impl Sync for MpvHandle {}

impl MpvHandle {
    pub fn create(options: &[(&str, &str)]) -> Result<Self, String> {
        let api = MpvApi::load()?;
        let ctx = unsafe { (api.create)() };
        if ctx.is_null() {
            return Err("mpv_create returned null".into());
        }

        // Se algo falhar daqui pra frente, o Drop destroi o contexto.
        let handle = Self { api, ctx };

        for (key, value) in options {
            // Opcoes opcionais: build sem a opcao nao deve impedir o start.
            let _ = handle.set_option(key, value);
        }

        let code = unsafe { (handle.api.initialize)(handle.ctx) };
        handle.check(code)?;
        Ok(handle)
    }

    pub fn error_text(&self, code: i32) -> String {
        let ptr = unsafe { (self.api.error_string)(code) };
        if ptr.is_null() {
            return format!("mpv error {code}");
        }
        let text = unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned();
        format!("{text} ({code})")
    }

    fn check(&self, code: c_int) -> Result<(), String> {
        if code >= 0 { Ok(()) } else { Err(self.error_text(code)) }
    }

    fn set_option(&self, name: &str, value: &str) -> Result<(), String> {
        let name = CString::new(name).map_err(|_| "NUL in option name".to_string())?;
        let value = CString::new(value).map_err(|_| "NUL in option value".to_string())?;
        let code =
            unsafe { (self.api.set_option_string)(self.ctx, name.as_ptr(), value.as_ptr()) };
        self.check(code)
    }

    pub fn set_property(&self, name: &str, value: &str) -> Result<(), String> {
        let name = CString::new(name).map_err(|_| "NUL in property name".to_string())?;
        let value = CString::new(value).map_err(|_| "NUL in property value".to_string())?;
        let code =
            unsafe { (self.api.set_property_string)(self.ctx, name.as_ptr(), value.as_ptr()) };
        self.check(code)
    }

    pub fn command(&self, args: &[&str]) -> Result<(), String> {
        let owned: Vec<CString> = args
            .iter()
            .map(|arg| CString::new(*arg).map_err(|_| "NUL in command argument".to_string()))
            .collect::<Result<_, _>>()?;
        let mut pointers: Vec<*const c_char> = owned.iter().map(|arg| arg.as_ptr()).collect();
        pointers.push(std::ptr::null());

        let code = unsafe { (self.api.command)(self.ctx, pointers.as_mut_ptr()) };
        self.check(code)
    }

    pub fn get_double(&self, name: &str) -> Option<f64> {
        let name = CString::new(name).ok()?;
        let mut value: f64 = 0.0;
        let code = unsafe {
            (self.api.get_property)(
                self.ctx,
                name.as_ptr(),
                MPV_FORMAT_DOUBLE,
                (&mut value as *mut f64).cast::<c_void>(),
            )
        };
        (code >= 0).then_some(value)
    }

    pub fn poll_event(&self) -> RawEvent {
        let event = unsafe { (self.api.wait_event)(self.ctx, 0.0) };
        if event.is_null() {
            return RawEvent::None;
        }
        let event = unsafe { &*event };

        match event.event_id {
            0 => RawEvent::None,
            MPV_EVENT_SHUTDOWN => RawEvent::Shutdown,
            MPV_EVENT_FILE_LOADED => RawEvent::FileLoaded,
            MPV_EVENT_END_FILE => {
                if event.data.is_null() {
                    RawEvent::EndFile { reason: END_FILE_REASON_EOF, error: 0 }
                } else {
                    let data = unsafe { &*(event.data as *const MpvEventEndFile) };
                    RawEvent::EndFile { reason: data.reason, error: data.error }
                }
            }
            _ => RawEvent::Other,
        }
    }
}

impl Drop for MpvHandle {
    fn drop(&mut self) {
        unsafe { (self.api.terminate_destroy)(self.ctx) };
    }
}