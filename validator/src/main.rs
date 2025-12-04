use std::path::PathBuf;

#[derive(argh::FromArgs)]
/// kubix validator
struct Arguments {
    /// directory containing CRD files, in json format
    #[argh(option, short = 'c')]
    crd_dir: PathBuf,

    /// directory containing resource manifest files to validate, in json format
    #[argh(option, short = 'm')]
    manifest_dir: PathBuf,
}

fn main() -> anyhow::Result<()> {
    let args: Arguments = argh::from_env();

    Ok(())
}
