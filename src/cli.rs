use clap::Parser;

/// EasyBoard - soundboard with a virtual microphone input.
#[derive(Parser, Debug, Default, Clone)]
#[command(
    name = "easyboard",
    version,
    author = "MrRedstonia <contact@mrredstonia.com>",
    about = "EasyBoard - soundboard with a virtual microphone input"
)]
pub struct Cli {
    /// Runs in the tray without UI.
    #[arg(short = 'n', long = "no-gui")]
    pub no_gui: bool,

    /// Plays sound by unique ID (e.g., 00, 01).
    #[arg(short = 'p', long = "play", value_name = "ID")]
    pub play: Vec<String>,

    /// Loop control: `-l on|off|toggle` for every sound, or `-l ID on|off|toggle` for one.
    #[arg(
        short = 'l',
        long = "loop",
        value_names = ["on|off|toggle|ID", "on|off|toggle"],
        num_args = 1..=2,
        action = clap::ArgAction::Append
    )]
    pub loop_arg: Vec<String>,

    /// Volume: `-v personal|sink|mic [VALUE]`. VALUE is a percentage: `50` sets it, `+10` raises,
    /// `-10` lowers; without VALUE the current volume is printed.
    #[arg(
        short = 'v',
        long = "volume",
        value_names = ["personal|sink|mic", "[+|-]PERCENT"],
        num_args = 1..=2,
        allow_hyphen_values = true,
        action = clap::ArgAction::Append
    )]
    pub volume: Vec<String>,

    /// Mute: `--mute personal|sink|mic [on|off|toggle]` (default toggle).
    #[arg(
        long = "mute",
        value_names = ["personal|sink|mic", "on|off|toggle"],
        num_args = 1..=2,
        action = clap::ArgAction::Append
    )]
    pub mute: Vec<String>,

    /// Lists every sound ("ID / Name"), sorted by ID. Options: `full` (also audio file, image, color and
    /// whether the color is hidden) and `sort=KEY` (id, name, length, color, added or manual; add `:desc`
    /// to reverse), e.g. `--list full sort=name`.
    #[arg(long = "list", value_name = "full|sort=KEY", num_args = 0..=2)]
    pub list: Option<Vec<String>>,

    /// Stops all playing audio.
    #[arg(short = 's', long = "stop")]
    pub stop: bool,
}

impl Cli {
    /// The actions as IPC command lines, in a sensible order
    /// (loop settings first, then stop, then plays).
    pub fn commands(&self) -> Result<Vec<String>, String> {
        let mode = |m: &str| -> Result<String, String> {
            match m.to_ascii_lowercase().as_str() {
                v @ ("on" | "off" | "toggle") => Ok(v.to_string()),
                _ => Err(format!("expected on, off or toggle, got '{m}'")),
            }
        };
        let is_mode = |m: &str| ["on", "off", "toggle"].contains(&m.to_ascii_lowercase().as_str());
        let mut v = Vec::new();
        let mut it = self.loop_arg.iter();
        while let Some(a) = it.next() {
            if is_mode(a) {
                v.push(format!("loop {}", mode(a)?));
            } else {
                match it.next() {
                    Some(m) => v.push(format!("loop {a} {}", mode(m)?)),
                    None => {
                        return Err(format!("--loop {a}: a sound ID needs on, off or toggle (e.g. -l {a} toggle)"))
                    }
                }
            }
        }
        let numeric = |t: &str| {
            let t = t.trim_end_matches('%');
            let t = t.strip_prefix(['+', '-']).unwrap_or(t);
            !t.is_empty() && t.parse::<f32>().is_ok()
        };
        let mut it = self.volume.iter().peekable();
        while let Some(target) = it.next() {
            match it.peek() {
                Some(val) if numeric(val) => {
                    let val = it.next().unwrap();
                    v.push(format!("volume {target} {val}"));
                }
                _ => v.push(format!("volume {target}")),
            }
        }
        let mut it = self.mute.iter().peekable();
        while let Some(target) = it.next() {
            match it.peek() {
                Some(m) if is_mode(m) => {
                    let m = it.next().unwrap();
                    v.push(format!("mute {target} {}", m.to_ascii_lowercase()));
                }
                _ => v.push(format!("mute {target}")),
            }
        }
        if self.stop {
            v.push("stop".into());
        }
        v.extend(self.play.iter().map(|id| format!("play {id}")));
        Ok(v)
    }
}
