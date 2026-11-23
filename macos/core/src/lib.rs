//! C interface to the ttfx fx engine for the macOS screensaver.
//!
//! A session runs one effect on a fixed grid. Each step makes one frame of
//! typed cells. The session does not write to stdout, does not install signal
//! handlers and does not start threads.

mod ansi;

use std::ffi::{c_char, c_int, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::OnceLock;

use clap::{CommandFactory, Parser};
use ttfx::cli::Cli;
use ttfx::effects::EffectCommand;
use ttfx::engine::canvas::Anchor;
use ttfx::engine::ctx::Clock;
use ttfx::engine::terminal::TerminalConfig;
use ttfx::fx::render::IoSlice;
use ttfx::fx::run::Effect;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

pub use ansi::Cell;

/// One effect run on a grid of `cols` x `rows` cells.
pub struct Session {
    effect: Box<dyn Effect>,
    engine: Engine,
    cells: Vec<Cell>,
    cols: usize,
    done: bool,
}

impl Session {
    /// Starts `effect_name` with its default options. The real clock is used,
    /// because `matrix` and `thunderstorm` read wall time.
    pub fn new(text: &str, effect_name: &str, cols: usize, rows: usize, seed: u64) -> Option<Self> {
        Self::with_clock(text, effect_name, cols, rows, seed, Clock::real())
    }

    pub fn with_clock(
        text: &str,
        effect_name: &str,
        cols: usize,
        rows: usize,
        seed: u64,
        clock: Clock,
    ) -> Option<Self> {
        if cols == 0 || rows == 0 {
            return None;
        }
        let command = default_command(effect_name)?;
        let mut effect = ttfx::fx::effects::build(&command)?;
        // An explicit canvas size with `ignore_terminal_dimensions` makes the
        // layout independent of the terminal size query.
        let config = TerminalConfig {
            canvas_width: cols as i64,
            canvas_height: rows as i64,
            anchor_text: Anchor::C,
            ignore_terminal_dimensions: true,
            ..TerminalConfig::default()
        };
        let mut engine = Engine::new(text, config, Rng::seeded(seed), clock).ok()?;
        effect.build(&mut engine).ok()?;
        Some(Session {
            effect,
            engine,
            cells: vec![Cell::BLANK; cols * rows],
            cols,
            done: false,
        })
    }

    /// Makes the next frame. Returns `false` when the effect is complete; the
    /// cells then keep the last frame.
    pub fn step(&mut self) -> bool {
        if self.done {
            return false;
        }
        if !self.effect.next_frame(&mut self.engine) {
            self.done = true;
            return false;
        }
        // The host paces the frames, thus `enforce_framerate` is not called.
        self.engine.clock.advance_frame();
        self.engine.render_here();
        let mut parts: Vec<IoSlice<'_>> = Vec::new();
        self.engine.renderer().frame_parts(&[], &[], &mut parts);
        ansi::parse_rows(parts.iter().map(|part| &**part), self.cols, &mut self.cells);
        true
    }

    /// The last frame, top row first.
    pub fn cells(&self) -> &[Cell] {
        &self.cells
    }
}

/// The effect with its default options, made the same way as for
/// `--random-effect` in `src/main.rs`.
fn default_command(name: &str) -> Option<EffectCommand> {
    Cli::try_parse_from(["ttfx", name]).ok()?.effect
}

/// The names of the effects that the fx engine can run with default options.
fn effect_names() -> &'static [CString] {
    static NAMES: OnceLock<Vec<CString>> = OnceLock::new();
    NAMES.get_or_init(|| {
        Cli::command()
            .get_subcommands()
            .map(|command| command.get_name().to_string())
            .filter(|name| {
                default_command(name).is_some_and(|c| ttfx::fx::effects::build(&c).is_some())
            })
            .filter_map(|name| CString::new(name).ok())
            .collect()
    })
}

// ------------------------------------------------------------- C interface

/// The number of effects.
#[no_mangle]
pub extern "C" fn ttfx_saver_effect_count() -> c_int {
    catch_unwind(|| effect_names().len() as c_int).unwrap_or(0)
}

/// The name of effect `index`, or null. The string is valid for the life of
/// the process.
#[no_mangle]
pub extern "C" fn ttfx_saver_effect_name(index: c_int) -> *const c_char {
    catch_unwind(|| {
        usize::try_from(index)
            .ok()
            .and_then(|index| effect_names().get(index))
            .map_or(std::ptr::null(), |name| name.as_ptr())
    })
    .unwrap_or(std::ptr::null())
}

/// Starts an effect. Returns null if the effect cannot start.
///
/// # Safety
/// `text` must point to `text_len` bytes. `effect_name` must be a C string.
#[no_mangle]
pub unsafe extern "C" fn ttfx_saver_new(
    text: *const u8,
    text_len: usize,
    effect_name: *const c_char,
    cols: c_int,
    rows: c_int,
    seed: u64,
) -> *mut Session {
    if text.is_null() || effect_name.is_null() || cols <= 0 || rows <= 0 {
        return std::ptr::null_mut();
    }
    // SAFETY: the caller gives valid pointers (see the function contract).
    let (text, name) = unsafe {
        (
            std::slice::from_raw_parts(text, text_len),
            CStr::from_ptr(effect_name),
        )
    };
    catch_unwind(|| {
        let text = String::from_utf8_lossy(text);
        let name = name.to_str().ok()?;
        Session::new(&text, name, cols as usize, rows as usize, seed)
    })
    .ok()
    .flatten()
    .map_or(std::ptr::null_mut(), |session| Box::into_raw(Box::new(session)))
}

/// Makes the next frame. 1 = frame ready, 0 = effect complete, -1 = error.
/// After an error, free the session.
///
/// # Safety
/// `session` must come from `ttfx_saver_new` and must not be freed.
#[no_mangle]
pub unsafe extern "C" fn ttfx_saver_step(session: *mut Session) -> c_int {
    // SAFETY: see the function contract.
    let Some(session) = (unsafe { session.as_mut() }) else {
        return -1;
    };
    match catch_unwind(AssertUnwindSafe(|| session.step())) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(_) => {
            // The engine state is not reliable after a panic.
            session.done = true;
            -1
        }
    }
}

/// The cells of the last frame: `cols * rows` cells, top row first. The
/// pointer is valid until the session is freed.
///
/// # Safety
/// `session` must come from `ttfx_saver_new` and must not be freed.
#[no_mangle]
pub unsafe extern "C" fn ttfx_saver_cells(session: *const Session) -> *const Cell {
    // SAFETY: see the function contract.
    match unsafe { session.as_ref() } {
        Some(session) => session.cells.as_ptr(),
        None => std::ptr::null(),
    }
}

/// Frees a session. Null is permitted.
///
/// # Safety
/// `session` must come from `ttfx_saver_new` and must not be freed before.
#[no_mangle]
pub unsafe extern "C" fn ttfx_saver_free(session: *mut Session) {
    if session.is_null() {
        return;
    }
    // SAFETY: see the function contract.
    let session = unsafe { Box::from_raw(session) };
    // A panic in a destructor must not go into the host.
    let _ = catch_unwind(AssertUnwindSafe(|| drop(session)));
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEXT: &str = "Hello, ttfx!\nSecond line\n  third";
    const COLS: usize = 80;
    const ROWS: usize = 24;
    const FRAME_LIMIT: usize = 200_000;

    fn names() -> Vec<String> {
        effect_names()
            .iter()
            .map(|name| name.to_str().unwrap().to_string())
            .collect()
    }

    fn rows_of(session: &Session) -> Vec<String> {
        session
            .cells()
            .chunks(COLS)
            .map(|row| {
                row.iter()
                    .map(|cell| char::from_u32(cell.codepoint).unwrap())
                    .collect()
            })
            .collect()
    }

    #[test]
    fn all_effects_are_available() {
        assert_eq!(names().len(), 37, "{:?}", names());
    }

    #[test]
    fn each_effect_completes_with_the_text_in_the_last_frame() {
        for name in names() {
            let clock = Clock::virtual_with_frame_rate(60);
            let mut session = Session::with_clock(TEXT, &name, COLS, ROWS, 7, clock)
                .unwrap_or_else(|| panic!("{name}: no session"));
            let mut frames = 0;
            while session.step() {
                frames += 1;
                assert_eq!(session.cells().len(), COLS * ROWS);
                assert!(frames < FRAME_LIMIT, "{name}: no end");
            }
            assert!(frames > 0, "{name}: no frames");
            let rows = rows_of(&session);
            for line in TEXT.lines() {
                assert!(
                    rows.iter().any(|row| row.contains(line.trim_end())),
                    "{name}: {line:?} is not in the last frame:\n{}",
                    rows.join("\n")
                );
            }
        }
    }

    #[test]
    fn the_same_seed_gives_the_same_frames() {
        let run = || {
            let clock = Clock::virtual_with_frame_rate(60);
            let mut session = Session::with_clock(TEXT, "decrypt", COLS, ROWS, 42, clock).unwrap();
            let mut frames = Vec::new();
            for _ in 0..50 {
                session.step();
                frames.push(session.cells().to_vec());
            }
            frames
        };
        assert_eq!(run(), run());
    }

    #[test]
    fn bad_arguments_give_no_session() {
        assert!(Session::new(TEXT, "no-such-effect", COLS, ROWS, 1).is_none());
        assert!(Session::new(TEXT, "decrypt", 0, ROWS, 1).is_none());
    }

    #[test]
    fn c_interface_runs_an_effect() {
        let name = CString::new("print").unwrap();
        // SAFETY: the pointers are valid and the session is freed one time.
        unsafe {
            let session = ttfx_saver_new(TEXT.as_ptr(), TEXT.len(), name.as_ptr(), 40, 10, 3);
            assert!(!session.is_null());
            assert_eq!(ttfx_saver_step(session), 1);
            assert!(!ttfx_saver_cells(session).is_null());
            ttfx_saver_free(session);
            assert_eq!(ttfx_saver_step(std::ptr::null_mut()), -1);
            ttfx_saver_free(std::ptr::null_mut());
        }
        assert_eq!(ttfx_saver_effect_count(), 37);
        assert!(ttfx_saver_effect_name(37).is_null());
        assert!(!ttfx_saver_effect_name(0).is_null());
    }
}
