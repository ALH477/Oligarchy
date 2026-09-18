//! Shared widget vocabulary.
//!
//! OWNER: work stream S2. The SIGNATURES of everything that existed at the S0
//! handoff are frozen — S3 and S4 code against them, so changing one breaks two
//! other streams. New helpers may be added; nothing may be removed or reshaped.
//!
//! `panel()` is the load-bearing one: it renders ANY `PanelState` with no new
//! UI code, which is what makes adding a subsystem a one-file change.
//!
//! Two house rules are enforced here rather than left to each pane:
//!
//! 1. **Health is never color alone.** Every `●` this module emits is followed
//!    by `Health::label()`, so the signal survives a no-color terminal and a
//!    colorblind reader. `dot()` is the only thing that emits the glyph.
//! 2. **Freshness is unmistakable.** `Fresh` renders normally; `Stale` dims
//!    every value, downgrades every per-row verdict to `--`, and stamps an age;
//!    `Failed` and `Unavailable` replace the body outright. A dashboard showing
//!    a stale green dot is worse than no dashboard.

use super::Skin;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Gauge, Paragraph, Row, Table, Wrap};
use ratatui::Frame;
use warroom_core::model::{Freshness, Health, Panel, PanelState, Table as ModelTable};

/// dsp-ctl's rule glyph. Every divider in the War Room is this character.
pub const RULE: &str = "━";
/// The filled cell of a compact inline meter.
pub const BAR_FULL: &str = "█";
/// The empty cell of a compact inline meter.
pub const BAR_EMPTY: &str = "░";

// ---------------------------------------------------------------------------
// text fitting
// ---------------------------------------------------------------------------

/// Truncate to `width` columns with an ellipsis. Every value that reaches a
/// cell goes through this: a collector is free to hand back a 400-character
/// error string, and a pane that lets one through wraps the layout apart.
pub fn fit(text: &str, width: usize) -> String {
    let n = text.chars().count();
    if n <= width {
        return text.to_string();
    }
    match width {
        0 => String::new(),
        1 => "…".to_string(),
        _ => {
            let mut out: String = text.chars().take(width - 1).collect();
            out.push('…');
            out
        }
    }
}

/// Rendered width of a composed line, for right-aligning a trailing span.
pub fn line_width(l: &Line<'_>) -> usize {
    l.spans.iter().map(|s| s.content.chars().count()).sum()
}

// ---------------------------------------------------------------------------
// chrome
// ---------------------------------------------------------------------------

/// Border/rule/track color that is actually visible.
///
/// Under the bare 16 ANSI colors the palette's border (#252530) and background
/// (#080810) both land on index 0 — every border, rule and gauge track in the
/// War Room would be black on black. `text_dim` (#808080) is the nearest
/// palette entry that survives that trip. This distro really does put people in
/// a bare TTY (tuigreet, recovery, the installer), which is exactly when a
/// cockpit matters most, so this is not a hypothetical.
///
/// The 256-color cube keeps the two apart (there is a test pinning that), so
/// there the real border color is used.
pub fn chrome(s: &Skin) -> ratatui::style::Color {
    match s.mode {
        warroom_core::theme::ColorMode::Ansi16 => s.text_dim(),
        warroom_core::theme::ColorMode::Ansi256 | warroom_core::theme::ColorMode::TrueColor => {
            s.border()
        }
    }
}

/// A bordered pane. Focused panes take the accent border.
pub fn block(s: &Skin, title: &str, focused: bool) -> Block<'static> {
    let (border, tint) = if focused {
        (s.border_focus(), s.accent())
    } else {
        (chrome(s), s.accent_dim())
    };
    Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Plain)
        .border_style(Style::default().fg(border))
        .title(Line::from(vec![
            Span::styled(" ▎", Style::default().fg(s.accent())),
            Span::styled(
                format!("{} ", title.to_uppercase()),
                Style::default().fg(tint).add_modifier(Modifier::BOLD),
            ),
        ]))
}

/// A horizontal rule in dsp-ctl's idiom.
pub fn rule(s: &Skin, width: usize) -> Line<'static> {
    Line::from(Span::styled(
        RULE.repeat(width),
        Style::default().fg(chrome(s)),
    ))
}

/// The ` ▎NAME ` pane title as a bare line, for sections inside a pane that do
/// not get a border of their own.
pub fn section(s: &Skin, title: &str) -> Line<'static> {
    Line::from(vec![
        Span::styled("▎", Style::default().fg(s.accent())),
        Span::styled(
            title.to_uppercase(),
            Style::default().fg(s.accent()).add_modifier(Modifier::BOLD),
        ),
    ])
}

// ---------------------------------------------------------------------------
// health and freshness
// ---------------------------------------------------------------------------

/// The health dot. ALWAYS emitted next to `Health::label()` text — a glyph that
/// carries meaning only in its color is unreadable to a chunk of users and
/// invisible in a no-color terminal. Nothing else in the tree emits `●`.
pub fn dot(s: &Skin, h: Health) -> Span<'static> {
    Span::styled("●", Style::default().fg(s.health(h)))
}

/// `● OK` — the dot and its mandatory text, as one unit.
pub fn verdict(s: &Skin, h: Health) -> Vec<Span<'static>> {
    vec![
        dot(s, h),
        Span::styled(
            format!(" {}", h.label()),
            Style::default().fg(s.health(h)).add_modifier(Modifier::BOLD),
        ),
    ]
}

/// Width of what [`verdict`] renders, for laying out around it.
fn verdict_width(h: Health) -> usize {
    1 + 1 + h.label().chars().count()
}

/// `LABEL:              value  ● OK`
///
/// `Health::Unknown` renders `● --` rather than nothing: a row that was judged
/// and is now stale must not look like a row that carries no judgement. Use
/// [`kv`] for genuinely unjudged information (kernel version, persona, ...).
pub fn stat(s: &Skin, label: &str, value: &str, h: Health, width: usize) -> Line<'static> {
    let vw = verdict_width(h);
    // The verdict is the one part that is never dropped: a row whose value got
    // clipped is still readable, a row whose OK/FAIL got clipped is a lie.
    let body = width.saturating_sub(vw + 1);
    if body < 4 {
        let mut spans = vec![Span::raw(" ".repeat(width.saturating_sub(vw)))];
        spans.extend(verdict(s, h));
        return Line::from(spans);
    }

    let label = fit(&format!("{}:", label.to_uppercase()), body - 3);
    let lw = label.chars().count();
    let value = fit(value, body - lw - 1);
    let pad = body - lw - value.chars().count();

    let mut spans = vec![
        Span::styled(label, Style::default().fg(s.text_dim())),
        Span::raw(" ".repeat(pad)),
        Span::styled(value, Style::default().fg(s.text())),
        Span::raw(" "),
    ];
    spans.extend(verdict(s, h));
    Line::from(spans)
}

/// `LABEL:                              value` — no verdict, for information
/// that carries none. Same right-aligned shape as [`stat`] so mixed blocks
/// still line up.
pub fn kv(s: &Skin, label: &str, value: &str, width: usize) -> Line<'static> {
    if width < 4 {
        return Line::from(Span::styled(
            fit(&label.to_uppercase(), width),
            Style::default().fg(s.text_dim()),
        ));
    }
    let label = fit(&format!("{}:", label.to_uppercase()), width - 3);
    let lw = label.chars().count();
    let value = fit(value, width - lw - 1);
    let pad = width - lw - value.chars().count();
    Line::from(vec![
        Span::styled(label, Style::default().fg(s.text_dim())),
        Span::raw(" ".repeat(pad)),
        Span::styled(value, Style::default().fg(s.text())),
    ])
}

/// How much the pane's data can be trusted, rendered so it cannot be mistaken
/// for fresh data. The abnormal states are shouted in caps on purpose.
pub fn freshness_span(s: &Skin, f: &Freshness) -> Span<'static> {
    match f {
        Freshness::Fresh => Span::styled("live", Style::default().fg(s.accent_dim())),
        Freshness::Stale(d) => Span::styled(
            format!("STALE {}", human_age(*d)),
            Style::default().fg(s.warning()).add_modifier(Modifier::BOLD),
        ),
        Freshness::Failed(_) => Span::styled(
            "FAILED".to_string(),
            Style::default().fg(s.error()).add_modifier(Modifier::BOLD),
        ),
        Freshness::Unavailable(_) => Span::styled("OFFLINE", Style::default().fg(s.text_dim())),
    }
}

pub fn human_age(d: std::time::Duration) -> String {
    let secs = d.as_secs();
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        format!("{}m{:02}s", secs / 60, secs % 60)
    } else {
        format!("{}h{:02}m", secs / 3600, (secs % 3600) / 60)
    }
}

/// `● OK  <headline> ................ live` — a pane's or card's top line.
pub fn status_line(
    s: &Skin,
    h: Health,
    headline: &str,
    fr: &Freshness,
    width: usize,
) -> Line<'static> {
    let fs = freshness_span(s, fr);
    let fw = fs.content.chars().count();
    let vw = verdict_width(h);
    let mut spans = verdict(s, h);
    // Too narrow to carry both signals: the verdict outranks the timestamp,
    // because a pane with no freshness stamp still reads as "unknown age".
    if width < vw + fw + 3 {
        return Line::from(spans);
    }

    let avail = width.saturating_sub(vw + fw + 3);
    let headline = fit(headline, avail);
    let pad = width
        .saturating_sub(vw + 2 + headline.chars().count() + fw)
        .max(1);

    spans.push(Span::raw("  "));
    spans.push(Span::styled(
        headline,
        Style::default().fg(if matches!(fr, Freshness::Fresh) {
            s.text()
        } else {
            s.text_dim()
        }),
    ));
    spans.push(Span::raw(" ".repeat(pad)));
    spans.push(fs);
    Line::from(spans)
}

// ---------------------------------------------------------------------------
// meters
// ---------------------------------------------------------------------------

/// dsp-ctl's thresholds, kept identical on purpose: two gauges in one distro
/// that disagree about what 70% means is worse than either choice.
pub fn meter_color(s: &Skin, pct: u16) -> ratatui::style::Color {
    if pct < 50 {
        s.success()
    } else if pct < 80 {
        s.warning()
    } else {
        s.error()
    }
}

/// Health implied by a meter reading, so a gauge and the dot beside it can
/// never disagree.
pub fn meter_health(pct: u16) -> Health {
    if pct < 50 {
        Health::Good
    } else if pct < 80 {
        Health::Warn
    } else {
        Health::Bad
    }
}

/// A two-row gauge: label plus verdict on the first row, bar on the second.
/// Thresholds are [`meter_color`]'s, which are dsp-ctl's.
///
/// The verdict is not decoration. A bar whose only warning is that it turned
/// yellow is a signal carried by hue alone — invisible on a no-color terminal
/// and to a chunk of readers — so the title line carries `● WARN` derived from
/// the same number that picked the color.
pub fn gauge(s: &Skin, label: &str, pct: u16) -> Gauge<'static> {
    let pct = pct.min(100);
    let mut title = vec![
        Span::styled(label.to_uppercase(), Style::default().fg(s.text_dim())),
        Span::raw("  "),
    ];
    title.extend(verdict(s, meter_health(pct)));
    Gauge::default()
        .block(Block::default().title(Line::from(title)))
        // The unfilled half is the gauge's track, not the pane background: a
        // bar with an invisible remainder reads as a shorter bar.
        .gauge_style(Style::default().fg(meter_color(s, pct)).bg(chrome(s)))
        .label(Span::styled(
            format!("{pct}%"),
            Style::default().add_modifier(Modifier::BOLD),
        ))
        .use_unicode(true)
        .percent(pct)
}

/// A one-row meter, for places too tight for [`gauge`]'s two rows (cards, a
/// short cockpit strip). Same thresholds, same reading.
///
/// `LOAD   ████████░░░░░░░░  42%`
pub fn bar_line(s: &Skin, label: &str, pct: u16, width: usize) -> Line<'static> {
    let pct = pct.min(100);
    let label = label.to_uppercase();
    let tail = format!(" {pct:>3}%");
    let lw = label.chars().count();
    // Below this there is no bar worth drawing; fall back to the number, which
    // is the part that actually carries the reading.
    if width < lw + tail.chars().count() + 6 {
        return kv(s, &label, &format!("{pct}%"), width);
    }
    let bar_w = width
        .saturating_sub(lw + tail.chars().count() + 2)
        .clamp(0, 48);
    let filled = (bar_w * pct as usize).div_ceil(100).min(bar_w);

    Line::from(vec![
        Span::styled(label, Style::default().fg(s.text_dim())),
        Span::raw("  "),
        Span::styled(
            BAR_FULL.repeat(filled),
            Style::default().fg(meter_color(s, pct)),
        ),
        Span::styled(
            BAR_EMPTY.repeat(bar_w - filled),
            Style::default().fg(chrome(s)),
        ),
        Span::styled(
            tail,
            Style::default()
                .fg(meter_color(s, pct))
                .add_modifier(Modifier::BOLD),
        ),
    ])
}

// ---------------------------------------------------------------------------
// reading a Panel back
// ---------------------------------------------------------------------------

/// Find a row whose label mentions any of `keys` (case-insensitive, in key
/// order). Panes read collector output by name rather than position so that a
/// collector adding a row never silently reshuffles a cockpit.
pub fn find_row<'a>(p: &'a Panel, keys: &[&str]) -> Option<&'a warroom_core::model::Row> {
    for k in keys {
        let k = k.to_lowercase();
        if let Some(r) = p.rows.iter().find(|r| r.label.to_lowercase().contains(&k)) {
            return Some(r);
        }
    }
    None
}

/// Pull a percentage out of a human-written value: `"71%"`, `"12.4G / 31.0G"`,
/// `"3.1 / 16"`. Returns `None` when the value plainly is not a ratio, which is
/// the caller's cue to render a stat line instead of a meter.
pub fn pct_from(value: &str) -> Option<u16> {
    if let Some(i) = value.find('%') {
        if let Some(v) = number_ending_at(&value[..i]) {
            return Some(v.clamp(0.0, 100.0).round() as u16);
        }
    }
    if let Some(i) = value.find('/') {
        let a = number_ending_at(&value[..i])?;
        let b = number_starting_at(&value[i + 1..])?;
        if b > 0.0 {
            return Some((a / b * 100.0).clamp(0.0, 100.0).round() as u16);
        }
    }
    None
}

/// The last number in `s`, ignoring trailing units and spaces (`"12.4 GiB"`).
fn number_ending_at(s: &str) -> Option<f32> {
    let chars: Vec<char> = s.chars().collect();
    let mut end = chars.len();
    while end > 0 && !chars[end - 1].is_ascii_digit() {
        end -= 1;
    }
    let mut start = end;
    while start > 0 && (chars[start - 1].is_ascii_digit() || chars[start - 1] == '.') {
        start -= 1;
    }
    if start == end {
        return None;
    }
    chars[start..end].iter().collect::<String>().parse().ok()
}

/// The first number in `s`, ignoring leading spaces (`" 31.0 GiB"`).
fn number_starting_at(s: &str) -> Option<f32> {
    let chars: Vec<char> = s.chars().collect();
    let mut start = 0;
    while start < chars.len() && !chars[start].is_ascii_digit() {
        start += 1;
    }
    let mut end = start;
    while end < chars.len() && (chars[end].is_ascii_digit() || chars[end] == '.') {
        end += 1;
    }
    if start == end {
        return None;
    }
    chars[start..end].iter().collect::<String>().parse().ok()
}

// ---------------------------------------------------------------------------
// dead states
// ---------------------------------------------------------------------------

/// The empty/dead state, in one place so every pane says the same thing the
/// same way. `bad` paints the headline in error color.
pub fn notice(s: &Skin, headline: &str, detail: &str, bad: bool) -> Paragraph<'static> {
    let head = if bad { s.error() } else { s.text_dim() };
    let mut lines = vec![Line::from(Span::styled(
        headline.to_string(),
        Style::default().fg(head).add_modifier(Modifier::BOLD),
    ))];
    if !detail.is_empty() {
        lines.push(Line::from(Span::styled(
            detail.to_string(),
            Style::default().fg(s.text_dim()),
        )));
    }
    Paragraph::new(lines).wrap(Wrap { trim: true })
}

/// The verdict a pane is allowed to *display*, which is not always the verdict
/// it holds. A `Stale` pane keeps its last-known health in the model — the JSON
/// snapshot wants it — but showing it would put a green dot on a reading nobody
/// has confirmed for minutes. `Failed` and `Unavailable` already map to Bad and
/// Unknown in `PanelState::health()`, so only `Stale` needs the downgrade.
pub fn shown_health(st: &PanelState) -> Health {
    match st.freshness {
        Freshness::Stale(_) => Health::Unknown,
        _ => st.health(),
    }
}

/// The dead state for a `PanelState`, or `None` when there is real data to
/// draw. Split out so `panel()` and `card()` cannot drift apart on what
/// "offline" versus "no contact" means.
fn dead_state(st: &PanelState) -> Option<(&'static str, String, bool)> {
    match &st.freshness {
        Freshness::Unavailable(why) => {
            Some(("SUBSYSTEM OFFLINE", (*why).to_string(), false))
        }
        Freshness::Failed(err) if st.panel.is_none() => {
            Some(("NO CONTACT", err.clone(), true))
        }
        _ if st.panel.is_none() => Some(("NO CONTACT", "awaiting first report".into(), false)),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// the load-bearing renderer
// ---------------------------------------------------------------------------

/// Render any `PanelState` — rows, optional table, freshness, and the
/// unavailable/failed states, in one place.
pub fn panel(f: &mut Frame, area: Rect, s: &Skin, st: &PanelState, focused: bool) {
    let blk = block(s, st.title, focused);
    let inner = blk.inner(area);
    f.render_widget(blk, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }

    // Dead states get one honest line instead of a stale-looking body.
    if let Some((head, detail, bad)) = dead_state(st) {
        return f.render_widget(notice(s, head, &detail, bad), inner);
    }
    let p = st.panel.as_ref().expect("dead_state covers the None case");

    // Stale data is dimmed wholesale AND every verdict is downgraded to `--`:
    // a stale green dot is worse than no dot.
    let stale = !matches!(st.freshness, Freshness::Fresh);
    let value_color = if stale { s.text_dim() } else { s.text() };

    let w = inner.width as usize;
    let h = inner.height as usize;

    let mut lines: Vec<Line> = vec![status_line(s, shown_health(st), &p.summary, &st.freshness, w)];
    if h > 1 {
        lines.push(rule(s, w));
    }

    // A table, when present, gets at least its header plus two rows before the
    // stat rows are allowed to use the remaining height.
    let n_table = p.table.as_ref().map(|t| t.rows.len()).unwrap_or(0);
    let reserve = if n_table > 0 {
        (n_table + 1).min(h.saturating_sub(4)).max(0)
    } else {
        0
    };
    let room = h.saturating_sub(lines.len() + reserve);

    if room > 0 && !p.rows.is_empty() {
        let fits = p.rows.len() <= room;
        let take = if fits { p.rows.len() } else { room.saturating_sub(1) };
        for r in p.rows.iter().take(take) {
            if stale {
                lines.push(stat(s, &r.label, &r.value, Health::Unknown, w));
            } else if r.health == Health::Unknown {
                lines.push(kv(s, &r.label, &r.value, w));
            } else {
                lines.push(stat(s, &r.label, &r.value, r.health, w));
            }
        }
        if !fits {
            lines.push(Line::from(Span::styled(
                format!("+{} more", p.rows.len() - take),
                Style::default().fg(s.text_dim()).add_modifier(Modifier::ITALIC),
            )));
        }
    }

    if reserve == 0 {
        // Dim every value in one go rather than per-span.
        return f.render_widget(
            Paragraph::new(lines).style(Style::default().fg(value_color)),
            inner,
        );
    }

    let split = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(lines.len() as u16), Constraint::Min(0)])
        .split(inner);
    f.render_widget(
        Paragraph::new(lines).style(Style::default().fg(value_color)),
        split[0],
    );
    render_table(f, split[1], s, p.table.as_ref().unwrap(), value_color);
}

/// Content-derived column widths, a capped row count, and an honest `+N more`
/// when the viewport runs out — a table that silently drops its tail is a
/// dashboard that lies by omission.
fn render_table(f: &mut Frame, area: Rect, s: &Skin, t: &ModelTable, value_color: ratatui::style::Color) {
    if area.height == 0 || area.width == 0 {
        return;
    }
    let ncols = t.headers.len().max(1);

    let mut maxw: Vec<usize> = t.headers.iter().map(|h| h.chars().count()).collect();
    maxw.resize(ncols, 0);
    for r in &t.rows {
        for (i, c) in r.iter().take(ncols).enumerate() {
            maxw[i] = maxw[i].max(c.chars().count());
        }
    }
    let widths: Vec<Constraint> = (0..ncols)
        .map(|i| {
            if i + 1 == ncols {
                Constraint::Min(6)
            } else {
                Constraint::Length(maxw[i].clamp(3, 28) as u16)
            }
        })
        .collect();

    let cap = area.height.saturating_sub(1) as usize;
    let fits = t.rows.len() <= cap;
    let take = if fits { t.rows.len() } else { cap.saturating_sub(1) };

    // The overflow marker is its own line under the table, not a table row: as
    // a row it lands in the first column and gets clipped to that column's
    // width, so `+36 more` renders as `+36 mor` — a truncation notice that is
    // itself truncated.
    let (body, tail) = if fits {
        (area, None)
    } else {
        let split = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Min(1), Constraint::Length(1)])
            .split(area);
        (split[0], Some(split[1]))
    };

    let rows: Vec<Row> = t
        .rows
        .iter()
        .take(take)
        .map(|r| {
            let cells: Vec<String> = (0..ncols)
                .map(|i| fit(r.get(i).map(String::as_str).unwrap_or(""), 28))
                .collect();
            Row::new(cells).style(Style::default().fg(value_color))
        })
        .collect();

    let header = Row::new(t.headers.iter().map(|h| h.to_uppercase()).collect::<Vec<_>>())
        .style(Style::default().fg(s.accent()).add_modifier(Modifier::BOLD));
    f.render_widget(
        Table::new(rows, widths).header(header).column_spacing(2),
        body,
    );
    if let Some(tail) = tail {
        f.render_widget(
            Paragraph::new(Line::from(Span::styled(
                fit(
                    &format!("+{} more", t.rows.len() - take),
                    tail.width as usize,
                ),
                Style::default().fg(s.accent_dim()).add_modifier(Modifier::ITALIC),
            ))),
            tail,
        );
    }
}

// ---------------------------------------------------------------------------
// the SITREP rollup tile
// ---------------------------------------------------------------------------

/// SITREP rollup card: one subsystem reduced to a verdict, a headline, and as
/// much detail as the tile has room for. This is the first thing anyone sees,
/// so it degrades in a defined order — verdict line, rule, headline, then
/// detail rows — rather than clipping whatever happens to be last.
pub fn card(f: &mut Frame, area: Rect, s: &Skin, st: &PanelState) {
    let blk = block(s, st.title, false);
    let inner = blk.inner(area);
    f.render_widget(blk, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }

    let w = inner.width as usize;
    let h = inner.height as usize;
    let stale = !matches!(st.freshness, Freshness::Fresh);

    let mut lines: Vec<Line> = vec![status_line(s, shown_health(st), "", &st.freshness, w)];
    if h >= 3 {
        lines.push(rule(s, w));
    }

    match dead_state(st) {
        Some((head, detail, bad)) => {
            lines.push(Line::from(Span::styled(
                head.to_string(),
                Style::default()
                    .fg(if bad { s.error() } else { s.text_dim() })
                    .add_modifier(Modifier::BOLD),
            )));
            if lines.len() < h {
                lines.push(Line::from(Span::styled(
                    fit(&detail, w),
                    Style::default().fg(s.text_dim()),
                )));
            }
        }
        None => {
            let p = st.panel.as_ref().expect("dead_state covers the None case");
            let summary_color = if stale { s.text_dim() } else { s.text() };
            lines.push(Line::from(Span::styled(
                fit(&p.summary, w),
                Style::default().fg(summary_color),
            )));

            // Detail rows fill whatever is left, best-first. A meter-shaped
            // value becomes a one-row bar; anything else becomes a stat line.
            for r in p.rows.iter() {
                if lines.len() >= h {
                    break;
                }
                let verdict_h = if stale { Health::Unknown } else { r.health };
                match pct_from(&r.value) {
                    Some(pct) if w >= 18 => lines.push(bar_line(s, &r.label, pct, w)),
                    _ if verdict_h == Health::Unknown => {
                        lines.push(kv(s, &r.label, &r.value, w))
                    }
                    _ => lines.push(stat(s, &r.label, &r.value, verdict_h, w)),
                }
            }
        }
    }

    lines.truncate(h);
    f.render_widget(Paragraph::new(lines), inner);
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    fn render_to_text(w: u16, h: u16, st: &PanelState) -> String {
        let s = Skin::new(warroom_core::theme::DEMOD);
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| panel(f, f.area(), &s, st, true)).unwrap();
        let buf = term.backend().buffer().clone();
        let mut out = String::new();
        for y in 0..h {
            for x in 0..w {
                out.push_str(buf[(x, y)].symbol());
            }
            out.push('\n');
        }
        out
    }

    fn peers(n: usize) -> PanelState {
        let mut st = PanelState::new("mesh", "MESH");
        st.freshness = Freshness::Fresh;
        st.panel = Some(
            Panel::new(Health::Good, format!("{n} peers"))
                .row("Node", "running", Health::Good)
                .plain("Listen", "0.0.0.0:5112")
                .table(
                    vec!["PEER".into(), "ADDR".into(), "RTT".into()],
                    (0..n)
                        .map(|i| {
                            vec![
                                format!("node-{i:02}"),
                                format!("10.0.0.{}", i + 2),
                                format!("{}.{} ms", i, i * 7 % 10),
                            ]
                        })
                        .collect(),
                ),
        );
        st
    }

    #[test]
    fn show_panel() {
        if std::env::var_os("WARROOM_SHOW").is_some() {
            for (w, h) in [(70u16, 16u16), (46, 10), (30, 8)] {
                println!("\n===== PANEL {w}x{h} =====");
                print!("{}", render_to_text(w, h, &peers(9)));
            }
        }
    }

    #[test]
    fn an_overflowing_table_says_how_much_it_hid() {
        // A table that silently drops its tail is a dashboard lying by
        // omission; the count is the whole point of the truncation.
        let out = render_to_text(70, 12, &peers(40));
        assert!(out.contains("more"), "no overflow marker:\n{out}");
        assert!(out.contains("PEER") && out.contains("ADDR"));
        // And a table that fits says nothing of the sort.
        let out = render_to_text(70, 20, &peers(3));
        assert!(!out.contains("more"), "false overflow marker:\n{out}");
        assert!(out.contains("node-02"));
    }

    #[test]
    fn a_panel_renders_at_every_size_without_panicking() {
        let mut dead = PanelState::new("forge", "FORGE");
        dead.freshness = Freshness::Unavailable("oligarchy-forge not installed");
        for w in [1u16, 3, 8, 16, 30, 46, 70, 140] {
            for h in [1u16, 2, 3, 5, 8, 12, 20, 45] {
                render_to_text(w, h, &peers(9));
                render_to_text(w, h, &dead);
            }
        }
    }

    #[test]
    fn fit_never_exceeds_its_budget() {
        for w in 0..12usize {
            assert!(fit("substantially too long", w).chars().count() <= w);
        }
        assert_eq!(fit("abc", 10), "abc");
        assert_eq!(fit("abcdef", 4), "abc…");
        // Multi-byte input must not panic or split a codepoint.
        assert_eq!(fit("━━━━━", 3).chars().count(), 3);
    }

    #[test]
    fn pct_reads_the_shapes_collectors_actually_emit() {
        assert_eq!(pct_from("71%"), Some(71));
        assert_eq!(pct_from("cpu 4.5% idle"), Some(5));
        assert_eq!(pct_from("12.4G / 31.0G"), Some(40));
        assert_eq!(pct_from("3.2 / 16"), Some(20));
        assert_eq!(pct_from("6.12.82-zen1"), None);
        assert_eq!(pct_from("performance"), None);
        // A ratio that overshoots is clamped, not wrapped.
        assert_eq!(pct_from("20 / 16"), Some(100));
        assert_eq!(pct_from("1 / 0"), None);
    }

    #[test]
    fn meter_thresholds_match_dsp_ctl() {
        assert_eq!(meter_health(0), Health::Good);
        assert_eq!(meter_health(49), Health::Good);
        assert_eq!(meter_health(50), Health::Warn);
        assert_eq!(meter_health(79), Health::Warn);
        assert_eq!(meter_health(80), Health::Bad);
    }

    #[test]
    fn a_bar_never_overruns_its_cell() {
        let s = Skin::new(warroom_core::theme::DEMOD);
        for w in 0..120usize {
            for pct in [0u16, 1, 50, 99, 100, 250] {
                let l = bar_line(&s, "load", pct, w);
                assert!(line_width(&l) <= w, "w={w} pct={pct} -> {}", line_width(&l));
            }
        }
    }

    #[test]
    fn chrome_never_lands_on_the_background_color() {
        use warroom_core::theme::{ColorMode, DEMOD};
        for mode in [ColorMode::TrueColor, ColorMode::Ansi16] {
            let s = Skin { p: DEMOD, mode };
            assert_ne!(chrome(&s), s.bg(), "{mode:?}: borders are invisible");
        }
    }

    #[test]
    fn every_dot_carries_its_label() {
        let s = Skin::new(warroom_core::theme::DEMOD);
        for h in [Health::Good, Health::Warn, Health::Bad, Health::Unknown] {
            let text: String = verdict(&s, h).iter().map(|sp| sp.content.to_string()).collect();
            assert!(text.starts_with('●'));
            assert!(text.contains(h.label()), "{text:?} lost {}", h.label());
        }
    }

    #[test]
    fn nothing_overruns_the_pane_it_was_given() {
        use warroom_core::model::Freshness;
        let s = Skin::new(warroom_core::theme::DEMOD);
        for w in 0..100usize {
            for h in [Health::Good, Health::Warn, Health::Bad, Health::Unknown] {
                let l = stat(&s, "netjack round trip", "2.67 ms (period 128)", h, w);
                assert!(line_width(&l) <= w.max(verdict_width(h)), "stat at w={w}");
                for fr in [
                    Freshness::Fresh,
                    Freshness::Stale(std::time::Duration::from_secs(90)),
                    Freshness::Failed("boom".into()),
                    Freshness::Unavailable("not installed"),
                ] {
                    let l = status_line(&s, h, "dsp vm running, 128 frames", &fr, w);
                    assert!(
                        line_width(&l) <= w.max(verdict_width(h)),
                        "status_line at w={w}"
                    );
                }
            }
            let l = kv(&s, "kernel", "6.12.82-zen1-with-a-long-suffix", w);
            assert!(line_width(&l) <= w, "kv overflowed at w={w}");
            assert!(line_width(&rule(&s, w)) == w);
        }
    }
}
