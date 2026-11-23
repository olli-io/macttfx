//! Converts one ANSI frame row from the fx renderer to typed cells.
//!
//! The renderer writes each cell as `SGR codes + symbol + ESC[0m`
//! (`format_visual` in `src/fx/visual.rs`). The parser is a general SGR state
//! machine, thus it also accepts the xterm-256 and basic colour forms.

use unicode_width::UnicodeWidthChar;

pub const ATTR_BOLD: u16 = 1 << 0;
pub const ATTR_DIM: u16 = 1 << 1;
pub const ATTR_ITALIC: u16 = 1 << 2;
pub const ATTR_UNDERLINE: u16 = 1 << 3;
pub const ATTR_BLINK: u16 = 1 << 4;
pub const ATTR_REVERSE: u16 = 1 << 5;
pub const ATTR_HIDDEN: u16 = 1 << 6;
pub const ATTR_STRIKE: u16 = 1 << 7;

pub const FLAG_FG: u8 = 1 << 0;
pub const FLAG_BG: u8 = 1 << 1;
pub const FLAG_WIDE: u8 = 1 << 2;

/// One character cell. The layout must agree with `ttfx_saver.h`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    /// Unicode scalar value.
    pub codepoint: u32,
    /// Foreground colour `0xRRGGBB`. Valid only with `FLAG_FG`.
    pub fg: u32,
    /// Background colour `0xRRGGBB`. Valid only with `FLAG_BG`.
    pub bg: u32,
    pub attrs: u16,
    pub flags: u8,
    pub reserved: u8,
}

impl Cell {
    pub const BLANK: Cell = Cell {
        codepoint: ' ' as u32,
        fg: 0,
        bg: 0,
        attrs: 0,
        flags: 0,
        reserved: 0,
    };
}

#[derive(Default, Clone, Copy)]
struct Style {
    fg: Option<u32>,
    bg: Option<u32>,
    attrs: u16,
}

/// Parses `rows` (top row first) into `cells`, which holds `cols` cells for
/// each row. Cells without data become blank.
pub fn parse_rows<'a>(rows: impl Iterator<Item = &'a [u8]>, cols: usize, cells: &mut [Cell]) {
    cells.fill(Cell::BLANK);
    if cols == 0 {
        return;
    }
    for (row, out) in rows.zip(cells.chunks_mut(cols)) {
        parse_row(row, out);
    }
}

/// Parses one row. The row ends at a line feed or at the end of the data.
pub fn parse_row(row: &[u8], out: &mut [Cell]) {
    let mut style = Style::default();
    let mut col = 0;
    let mut i = 0;
    while i < row.len() {
        let byte = row[i];
        if byte == b'\n' {
            break;
        }
        if byte == 0x1b {
            i = escape(row, i, &mut style);
            continue;
        }
        let (ch, len) = decode(&row[i..]);
        i += len;
        // Control and zero-width characters do not use a cell.
        let width = match ch.width() {
            Some(width) if width > 0 => width,
            _ => continue,
        };
        if col < out.len() {
            let mut flags = 0;
            if style.fg.is_some() {
                flags |= FLAG_FG;
            }
            if style.bg.is_some() {
                flags |= FLAG_BG;
            }
            if width > 1 {
                flags |= FLAG_WIDE;
            }
            out[col] = Cell {
                codepoint: ch as u32,
                fg: style.fg.unwrap_or(0),
                bg: style.bg.unwrap_or(0),
                attrs: style.attrs,
                flags,
                reserved: 0,
            };
        }
        col += 1;
    }
}

/// Reads the escape sequence at `start` and returns the index after it.
fn escape(row: &[u8], start: usize, style: &mut Style) -> usize {
    if row.get(start + 1) != Some(&b'[') {
        // Not a CSI sequence: ignore the escape byte and the byte after it.
        return (start + 2).min(row.len());
    }
    let params_start = start + 2;
    let mut end = params_start;
    while end < row.len() && !(0x40..=0x7e).contains(&row[end]) {
        end += 1;
    }
    if end < row.len() && row[end] == b'm' {
        sgr(&row[params_start..end], style);
    }
    (end + 1).min(row.len())
}

fn sgr(params: &[u8], style: &mut Style) {
    let mut values = params.split(|&b| b == b';').map(|part| {
        part.iter()
            .filter(|b| b.is_ascii_digit())
            .fold(0u32, |n, &b| n.saturating_mul(10).saturating_add((b - b'0') as u32))
    });
    while let Some(code) = values.next() {
        match code {
            0 => *style = Style::default(),
            1 => style.attrs |= ATTR_BOLD,
            2 => style.attrs |= ATTR_DIM,
            3 => style.attrs |= ATTR_ITALIC,
            4 => style.attrs |= ATTR_UNDERLINE,
            5 => style.attrs |= ATTR_BLINK,
            7 => style.attrs |= ATTR_REVERSE,
            8 => style.attrs |= ATTR_HIDDEN,
            9 => style.attrs |= ATTR_STRIKE,
            22 => style.attrs &= !(ATTR_BOLD | ATTR_DIM),
            23 => style.attrs &= !ATTR_ITALIC,
            24 => style.attrs &= !ATTR_UNDERLINE,
            25 => style.attrs &= !ATTR_BLINK,
            27 => style.attrs &= !ATTR_REVERSE,
            28 => style.attrs &= !ATTR_HIDDEN,
            29 => style.attrs &= !ATTR_STRIKE,
            30..=37 => style.fg = Some(xterm_to_rgb(code - 30)),
            38 => style.fg = extended_color(&mut values).or(style.fg),
            39 => style.fg = None,
            40..=47 => style.bg = Some(xterm_to_rgb(code - 40)),
            48 => style.bg = extended_color(&mut values).or(style.bg),
            49 => style.bg = None,
            90..=97 => style.fg = Some(xterm_to_rgb(code - 90 + 8)),
            100..=107 => style.bg = Some(xterm_to_rgb(code - 100 + 8)),
            _ => {}
        }
    }
}

/// The colour after `38` or `48`: `5;n` or `2;r;g;b`.
fn extended_color(values: &mut impl Iterator<Item = u32>) -> Option<u32> {
    match values.next()? {
        5 => Some(xterm_to_rgb(values.next()?)),
        2 => {
            let r = values.next()?.min(255);
            let g = values.next()?.min(255);
            let b = values.next()?.min(255);
            Some(r << 16 | g << 8 | b)
        }
        _ => None,
    }
}

/// The standard xterm 256-colour palette.
fn xterm_to_rgb(code: u32) -> u32 {
    const BASIC: [u32; 16] = [
        0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xc0c0c0, 0x808080,
        0xff0000, 0x00ff00, 0xffff00, 0x0000ff, 0xff00ff, 0x00ffff, 0xffffff,
    ];
    match code {
        0..=15 => BASIC[code as usize],
        16..=231 => {
            let level = |n: u32| if n == 0 { 0 } else { 55 + 40 * n };
            let n = code - 16;
            level(n / 36) << 16 | level(n / 6 % 6) << 8 | level(n % 6)
        }
        232..=255 => {
            let grey = 8 + 10 * (code - 232);
            grey << 16 | grey << 8 | grey
        }
        _ => 0,
    }
}

/// Decodes the first UTF-8 character of `bytes` (not empty). Bad data gives
/// U+FFFD and a length of one byte.
fn decode(bytes: &[u8]) -> (char, usize) {
    let len = match bytes[0] {
        0x00..=0x7f => return (bytes[0] as char, 1),
        0xc0..=0xdf => 2,
        0xe0..=0xef => 3,
        0xf0..=0xf7 => 4,
        _ => return (char::REPLACEMENT_CHARACTER, 1),
    };
    bytes
        .get(..len)
        .and_then(|part| std::str::from_utf8(part).ok())
        .and_then(|text| text.chars().next())
        .map_or((char::REPLACEMENT_CHARACTER, 1), |ch| (ch, len))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(data: &str, cols: usize) -> Vec<Cell> {
        let mut out = vec![Cell::BLANK; cols];
        parse_row(data.as_bytes(), &mut out);
        out
    }

    #[test]
    fn plain_text_and_blank_fill() {
        let cells = row("ab\n", 4);
        assert_eq!(cells[0].codepoint, 'a' as u32);
        assert_eq!(cells[1].codepoint, 'b' as u32);
        assert_eq!(cells[2], Cell::BLANK);
        assert_eq!(cells[3], Cell::BLANK);
    }

    #[test]
    fn rgb_colors_end_at_reset() {
        let cells = row("\x1b[38;2;1;2;3m\x1b[48;2;255;0;16mx\x1b[0my", 2);
        assert_eq!(cells[0].fg, 0x010203);
        assert_eq!(cells[0].bg, 0xff0010);
        assert_eq!(cells[0].flags, FLAG_FG | FLAG_BG);
        assert_eq!(cells[1].codepoint, 'y' as u32);
        assert_eq!(cells[1].flags, 0);
    }

    #[test]
    fn xterm_colors() {
        let cells = row("\x1b[38;5;196ma\x1b[0m\x1b[48;5;244mb\x1b[0m\x1b[38;5;9mc", 3);
        assert_eq!(cells[0].fg, 0xff0000);
        assert_eq!(cells[1].bg, 0x808080);
        assert_eq!(cells[1].flags, FLAG_BG);
        assert_eq!(cells[2].fg, 0xff0000);
    }

    #[test]
    fn attributes() {
        let cells = row("\x1b[1m\x1b[3m\x1b[4m\x1b[5m\x1b[7m\x1b[8m\x1b[9mx\x1b[0my", 2);
        assert_eq!(
            cells[0].attrs,
            ATTR_BOLD
                | ATTR_ITALIC
                | ATTR_UNDERLINE
                | ATTR_BLINK
                | ATTR_REVERSE
                | ATTR_HIDDEN
                | ATTR_STRIKE
        );
        assert_eq!(cells[1].attrs, 0);
    }

    #[test]
    fn wide_and_zero_width_characters() {
        let cells = row("世e\u{301}█", 4);
        assert_eq!(cells[0].codepoint, '世' as u32);
        assert_eq!(cells[0].flags, FLAG_WIDE);
        assert_eq!(cells[1].codepoint, 'e' as u32);
        assert_eq!(cells[2].codepoint, '█' as u32);
        assert_eq!(cells[2].flags, 0);
        assert_eq!(cells[3], Cell::BLANK);
    }

    #[test]
    fn data_after_the_last_column_is_ignored() {
        let cells = row("abcdef", 2);
        assert_eq!(cells.len(), 2);
        assert_eq!(cells[1].codepoint, 'b' as u32);
    }

    #[test]
    fn bad_data_does_not_panic() {
        row("\x1b", 2);
        row("\x1b[38;2;1", 2);
        row("\x1b[38;5m\x1b[48;2;1mx", 2);
        let mut out = vec![Cell::BLANK; 2];
        parse_row(&[0xff, 0xe4, b'a'], &mut out);
        assert_eq!(out[0].codepoint, char::REPLACEMENT_CHARACTER as u32);
    }

    #[test]
    fn rows_fill_the_grid_top_first() {
        let mut cells = vec![Cell::BLANK; 6];
        let rows: [&[u8]; 2] = [b"ab\n", b"c\n"];
        parse_rows(rows.into_iter(), 2, &mut cells);
        let text: String = cells
            .iter()
            .map(|c| char::from_u32(c.codepoint).unwrap())
            .collect();
        assert_eq!(text, "abc   ");
    }
}
