use std::path::PathBuf;

use anyhow::bail;
use k8s_openapi::apiextensions_apiserver::pkg::apis::apiextensions::v1::CustomResourceDefinition;
use kube::api::DynamicObject;

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

    let crds: Vec<(String, CustomResourceDefinition)> = try_parse_directory_files(&args.crd_dir)?;
    let manifests: Vec<(String, DynamicObject)> = try_parse_directory_files(&args.manifest_dir)?;

    let errors = do_validation(crds, manifests);

    if !errors.is_empty() {
        for error in &errors {
            eprintln!("Error: {}", error);
        }

        bail!("validation failed with {} errors", errors.len());
    }

    Ok(())
}

fn do_validation(
    crds: Vec<(String, CustomResourceDefinition)>,
    manifests: Vec<(String, DynamicObject)>,
) -> Vec<anyhow::Error> {
    let mut errors = Vec::new();

    // verify each manifest against the CRDs
    for (name, manifest) in manifests {
        let Ok(manifest_value) = serde_json::to_value(&manifest) else {
            errors.push(anyhow::anyhow!(
                "{:?}: failed to serialize manifest to JSON value",
                name
            ));
            continue;
        };
        let Some(types) = manifest.types else {
            errors.push(anyhow::anyhow!("{:?}: missing TypeMeta", name));
            continue;
        };

        let api_version = types.api_version;
        let kind = types.kind;

        // parse api_version into group and version
        let (group, version) = if let Some((g, v)) = api_version.rsplit_once('/') {
            (g.to_string(), v.to_string())
        } else {
            ("".to_string(), api_version)
        };

        // find matching CRD
        for (_, crd) in &crds {
            let crd_name = crd.metadata.name.clone().unwrap_or_default();
            let crd_group = crd.spec.group.clone();
            let crd_kind = crd.spec.names.kind.clone();

            if crd_group != group || crd_kind != kind {
                continue;
            }

            // find matching version
            let version_found = crd
                .spec
                .versions
                .iter()
                .find(|v| v.name == version)
                .cloned();

            let Some(version_spec) = version_found else {
                errors.push(anyhow::anyhow!(
                    "{:?}: no matching version {:?} in CRD {:?}",
                    name,
                    version,
                    crd_name
                ));
                continue;
            };

            let schema = if let Some(schema) = version_spec.schema {
                schema
            } else {
                errors.push(anyhow::anyhow!(
                    "{:?}: no schema found in CRD {:?} version {:?}",
                    name,
                    crd_name,
                    version
                ));
                continue;
            };

            let schema = if let Some(open_api_v3_schema) = schema.open_api_v3_schema {
                open_api_v3_schema
            } else {
                errors.push(anyhow::anyhow!(
                    "{:?}: no OpenAPI v3 schema found in CRD {:?} version {:?}",
                    name,
                    crd_name,
                    version
                ));
                continue;
            };

            // do validation
            let Ok(schema) = serde_json::to_value(&schema) else {
                errors.push(anyhow::anyhow!(
                    "{:?}: empty schema in CRD {:?} version {:?}",
                    name,
                    crd_name,
                    version
                ));
                continue;
            };
            let Ok(validator) = jsonschema::validator_for(&schema) else {
                errors.push(anyhow::anyhow!(
                    "{:?}: failed to create validator for CRD {:?} version {:?}",
                    name,
                    crd_name,
                    version
                ));
                continue;
            };
            let result = validator.validate(&manifest_value);
            if let Err(e) = result {
                let instance_path = e.instance_path().to_string();
                errors.push(anyhow::anyhow!(
                    "{:?}: validation error at {}: {}",
                    name,
                    instance_path,
                    e
                ));
            }
        }
    }

    errors
}

fn try_parse_directory_files<T: serde::de::DeserializeOwned>(
    dir: &PathBuf,
) -> anyhow::Result<Vec<(String, T)>> {
    let mut items = Vec::new();
    if !dir.is_dir() {
        bail!("directory does not exist or is not a directory");
    }
    for entry in std::fs::read_dir(dir)? {
        let entry_path = entry?.path();
        if entry_path.is_dir() {
            continue;
        }
        let file_name = entry_path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("unknown")
            .to_string();
        let content = std::fs::read(&entry_path)?;
        if let Ok(item) = serde_json::from_slice::<T>(&content) {
            // parse as single item
            items.push((file_name, item));
        } else if let Ok(item_list) =
            // parse as list of items
            serde_json::from_slice::<Vec<T>>(&content)
        {
            for item in item_list {
                items.push((file_name.clone(), item));
            }
        } else {
            bail!("failed to parse file: {:?}", entry_path);
        }
    }

    Ok(items)
}
