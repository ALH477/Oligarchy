fn main() {
    if let Err(err) = reliquary::cli::run() {
        eprintln!("reliquary: {err:#}");
        std::process::exit(1);
    }
}
