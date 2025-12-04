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
        let mut crd_found = false;
        for (_, crd) in &crds {
            let crd_name = crd.metadata.name.clone().unwrap_or_default();
            let crd_group = crd.spec.group.clone();
            let crd_kind = crd.spec.names.kind.clone();

            if crd_group != group || crd_kind != kind {
                continue;
            }

            crd_found = true;

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

        if !crd_found {
            errors.push(anyhow::anyhow!(
                "{:?}: no matching CRD found for {}/{}",
                name,
                group,
                kind
            ));
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

#[cfg(test)]
mod tests {
    use super::*;
    use k8s_openapi::apiextensions_apiserver::pkg::apis::apiextensions::v1::{
        CustomResourceDefinitionNames, CustomResourceDefinitionSpec,
        CustomResourceDefinitionVersion, CustomResourceValidation, JSONSchemaProps,
    };
    use k8s_openapi::apimachinery::pkg::apis::meta::v1::ObjectMeta;
    use kube::api::TypeMeta;
    use serde_json::json;

    fn make_crd(
        group: &str,
        kind: &str,
        version: &str,
        schema: Option<JSONSchemaProps>,
    ) -> CustomResourceDefinition {
        CustomResourceDefinition {
            metadata: ObjectMeta {
                name: Some(format!("{}s.{}", kind.to_lowercase(), group)),
                ..Default::default()
            },
            spec: CustomResourceDefinitionSpec {
                group: group.to_string(),
                names: CustomResourceDefinitionNames {
                    kind: kind.to_string(),
                    plural: format!("{}s", kind.to_lowercase()),
                    ..Default::default()
                },
                scope: "Namespaced".to_string(),
                versions: vec![CustomResourceDefinitionVersion {
                    name: version.to_string(),
                    served: true,
                    storage: true,
                    schema: schema.map(|s| CustomResourceValidation {
                        open_api_v3_schema: Some(s),
                    }),
                    ..Default::default()
                }],
                ..Default::default()
            },
            status: None,
        }
    }

    fn make_manifest(api_version: &str, kind: &str, name: &str) -> DynamicObject {
        DynamicObject {
            types: Some(TypeMeta {
                api_version: api_version.to_string(),
                kind: kind.to_string(),
            }),
            metadata: ObjectMeta {
                name: Some(name.to_string()),
                ..Default::default()
            },
            data: json!({}),
        }
    }

    fn make_manifest_with_data(
        api_version: &str,
        kind: &str,
        name: &str,
        data: serde_json::Value,
    ) -> DynamicObject {
        DynamicObject {
            types: Some(TypeMeta {
                api_version: api_version.to_string(),
                kind: kind.to_string(),
            }),
            metadata: ObjectMeta {
                name: Some(name.to_string()),
                ..Default::default()
            },
            data,
        }
    }

    fn simple_schema() -> JSONSchemaProps {
        JSONSchemaProps {
            type_: Some("object".to_string()),
            properties: Some(
                [
                    (
                        "apiVersion".to_string(),
                        JSONSchemaProps {
                            type_: Some("string".to_string()),
                            ..Default::default()
                        },
                    ),
                    (
                        "kind".to_string(),
                        JSONSchemaProps {
                            type_: Some("string".to_string()),
                            ..Default::default()
                        },
                    ),
                    (
                        "metadata".to_string(),
                        JSONSchemaProps {
                            type_: Some("object".to_string()),
                            ..Default::default()
                        },
                    ),
                    (
                        "spec".to_string(),
                        JSONSchemaProps {
                            type_: Some("object".to_string()),
                            properties: Some(
                                [(
                                    "replicas".to_string(),
                                    JSONSchemaProps {
                                        type_: Some("integer".to_string()),
                                        ..Default::default()
                                    },
                                )]
                                .into_iter()
                                .collect(),
                            ),
                            ..Default::default()
                        },
                    ),
                ]
                .into_iter()
                .collect(),
            ),
            ..Default::default()
        }
    }

    #[test]
    fn test_valid_manifest_passes_validation() {
        let crd = make_crd("example.com", "MyResource", "v1", Some(simple_schema()));
        let manifest = make_manifest_with_data(
            "example.com/v1",
            "MyResource",
            "test-resource",
            json!({"spec": {"replicas": 3}}),
        );

        let errors = do_validation(
            vec![("crd.json".to_string(), crd)],
            vec![("manifest.json".to_string(), manifest)],
        );

        assert!(errors.is_empty(), "Expected no errors, got: {:?}", errors);
    }

    #[test]
    fn test_missing_type_meta() {
        let crd = make_crd("example.com", "MyResource", "v1", Some(simple_schema()));
        let manifest = DynamicObject {
            types: None,
            metadata: ObjectMeta {
                name: Some("test-resource".to_string()),
                ..Default::default()
            },
            data: json!({}),
        };

        let errors = do_validation(
            vec![("crd.json".to_string(), crd)],
            vec![("manifest.json".to_string(), manifest)],
        );

        assert_eq!(errors.len(), 1);
        assert!(errors[0].to_string().contains("missing TypeMeta"));
    }

    #[test]
    fn test_no_matching_version_in_crd() {
        let crd = make_crd("example.com", "MyResource", "v1", Some(simple_schema()));
        let manifest = make_manifest("example.com/v2", "MyResource", "test-resource");

        let errors = do_validation(
            vec![("crd.json".to_string(), crd)],
            vec![("manifest.json".to_string(), manifest)],
        );

        assert_eq!(errors.len(), 1);
        assert!(errors[0].to_string().contains("no matching version"));
    }

    #[test]
    fn test_no_schema_in_crd() {
        let crd = make_crd("example.com", "MyResource", "v1", None);
        let manifest = make_manifest("example.com/v1", "MyResource", "test-resource");

        let errors = do_validation(
            vec![("crd.json".to_string(), crd)],
            vec![("manifest.json".to_string(), manifest)],
        );

        assert_eq!(errors.len(), 1);
        assert!(errors[0].to_string().contains("no schema found"));
    }

    #[test]
    fn test_validation_error_wrong_type() {
        let schema = JSONSchemaProps {
            type_: Some("object".to_string()),
            properties: Some(
                [
                    (
                        "apiVersion".to_string(),
                        JSONSchemaProps {
                            type_: Some("string".to_string()),
                            ..Default::default()
                        },
                    ),
                    (
                        "kind".to_string(),
                        JSONSchemaProps {
                            type_: Some("string".to_string()),
                            ..Default::default()
                        },
                    ),
                    (
                        "metadata".to_string(),
                        JSONSchemaProps {
                            type_: Some("object".to_string()),
                            ..Default::default()
                        },
                    ),
                    (
                        "spec".to_string(),
                        JSONSchemaProps {
                            type_: Some("object".to_string()),
                            properties: Some(
                                [(
                                    "replicas".to_string(),
                                    JSONSchemaProps {
                                        type_: Some("integer".to_string()),
                                        ..Default::default()
                                    },
                                )]
                                .into_iter()
                                .collect(),
                            ),
                            required: Some(vec!["replicas".to_string()]),
                            ..Default::default()
                        },
                    ),
                ]
                .into_iter()
                .collect(),
            ),
            required: Some(vec!["spec".to_string()]),
            ..Default::default()
        };

        let crd = make_crd("example.com", "MyResource", "v1", Some(schema));
        // provide replicas as a string instead of an integer
        let manifest = make_manifest_with_data(
            "example.com/v1",
            "MyResource",
            "test-resource",
            json!({"spec": {"replicas": "not-a-number"}}),
        );

        let errors = do_validation(
            vec![("crd.json".to_string(), crd)],
            vec![("manifest.json".to_string(), manifest)],
        );

        assert_eq!(errors.len(), 1);
        assert!(errors[0].to_string().contains("validation error"));
    }

    #[test]
    fn test_no_matching_crd() {
        let crd = make_crd("example.com", "MyResource", "v1", Some(simple_schema()));
        let manifest = make_manifest("other.com/v1", "OtherResource", "test-resource");

        let errors = do_validation(
            vec![("crd.json".to_string(), crd)],
            vec![("manifest.json".to_string(), manifest)],
        );

        assert_eq!(errors.len(), 1);
        assert!(errors[0].to_string().contains("no matching CRD found"));
    }

    #[test]
    fn test_core_api_version_without_group() {
        // test api_version without a group (e.g., "v1" instead of "group/v1")
        let crd = make_crd("", "Pod", "v1", Some(simple_schema()));
        let manifest = make_manifest("v1", "Pod", "test-pod");

        let errors = do_validation(
            vec![("crd.json".to_string(), crd)],
            vec![("manifest.json".to_string(), manifest)],
        );

        assert!(errors.is_empty(), "Expected no errors, got: {:?}", errors);
    }

    #[test]
    fn test_multiple_manifests_multiple_errors() {
        let crd = make_crd("example.com", "MyResource", "v1", Some(simple_schema()));

        let manifest1 = DynamicObject {
            types: None,
            metadata: ObjectMeta {
                name: Some("no-type-meta".to_string()),
                ..Default::default()
            },
            data: json!({}),
        };

        let manifest2 = make_manifest("example.com/v2", "MyResource", "wrong-version");

        let errors = do_validation(
            vec![("crd.json".to_string(), crd)],
            vec![
                ("manifest1.json".to_string(), manifest1),
                ("manifest2.json".to_string(), manifest2),
            ],
        );

        assert_eq!(errors.len(), 2);
        assert!(errors[0].to_string().contains("missing TypeMeta"));
        assert!(errors[1].to_string().contains("no matching version"));
    }

    #[test]
    fn test_multiple_crds_finds_correct_one() {
        let crd1 = make_crd("example.com", "ResourceA", "v1", Some(simple_schema()));
        let crd2 = make_crd("example.com", "ResourceB", "v1", Some(simple_schema()));
        let crd3 = make_crd("other.com", "ResourceA", "v1", Some(simple_schema()));

        let manifest = make_manifest_with_data(
            "example.com/v1",
            "ResourceB",
            "test-resource",
            json!({"spec": {"replicas": 5}}),
        );

        let errors = do_validation(
            vec![
                ("crd1.json".to_string(), crd1),
                ("crd2.json".to_string(), crd2),
                ("crd3.json".to_string(), crd3),
            ],
            vec![("manifest.json".to_string(), manifest)],
        );

        assert!(errors.is_empty(), "Expected no errors, got: {:?}", errors);
    }

    #[test]
    fn test_empty_manifests_returns_no_errors() {
        let crd = make_crd("example.com", "MyResource", "v1", Some(simple_schema()));

        let errors = do_validation(vec![("crd.json".to_string(), crd)], vec![]);

        assert!(errors.is_empty());
    }

    #[test]
    fn test_empty_crds_returns_error() {
        let manifest = make_manifest("example.com/v1", "MyResource", "test-resource");

        let errors = do_validation(vec![], vec![("manifest.json".to_string(), manifest)]);

        assert_eq!(errors.len(), 1);
        assert!(errors[0].to_string().contains("no matching CRD found"));
    }
}
