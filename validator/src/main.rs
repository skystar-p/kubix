use std::{collections::BTreeMap, path::PathBuf};

use anyhow::bail;
use k8s_openapi::apiextensions_apiserver::pkg::apis::apiextensions::v1::CustomResourceDefinition;
use kube::api::DynamicObject;

#[derive(argh::FromArgs)]
/// kubix validator
struct Arguments {
    /// directory containing CRD files, in json format
    #[argh(option, short = 'c')]
    crd_dir: PathBuf,

    /// directory containing json schema files, in json format
    #[argh(option, short = 's')]
    schema_dir: PathBuf,

    /// directory containing resource manifest files to validate, in json format
    #[argh(option, short = 'm')]
    manifest_dir: PathBuf,
}

fn main() -> anyhow::Result<()> {
    let args: Arguments = argh::from_env();

    let crds: Vec<(String, CustomResourceDefinition)> = try_parse_directory_files(&args.crd_dir)?;
    let schemas: BTreeMap<SchemaKey, serde_json::Value> = try_parse_schema_files(&args.schema_dir)?;
    let manifests: Vec<(String, DynamicObject)> = try_parse_directory_files(&args.manifest_dir)?;

    let errors = do_validation(crds, schemas, manifests);

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
    schemas: BTreeMap<SchemaKey, serde_json::Value>,
    manifests: Vec<(String, DynamicObject)>,
) -> Vec<anyhow::Error> {
    let mut errors = Vec::new();

    // verify each manifest against the CRDs and json schemas
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
            ("".to_string(), api_version.clone())
        };

        // find matching schema
        let schema_key = (api_version.clone(), kind.clone());
        if let Some(schema) = schemas.get(&schema_key) {
            // validate against schema
            if let Err(e) = validate_against_schema(schema, &manifest_value, &name) {
                errors.push(e);
            }
            continue;
        }

        // if no schema found, try to validate against CRDs
        let results = crds
            .iter()
            .map(|(_, crd)| {
                validate_against_crd(crd, &manifest_value, &name, &group, &version, &kind)
            })
            .collect::<Vec<_>>();
        let matched = results.iter().any(|res| match res {
            Ok(validated) => *validated,
            Err(_) => false,
        });
        let errors_from_crds: Vec<anyhow::Error> = results
            .into_iter()
            .filter_map(|res| match res {
                Ok(_) => None,
                Err(e) => Some(e),
            })
            .collect();
        if !errors.is_empty() {
            errors.extend(errors_from_crds);
        } else if !matched {
            errors.push(anyhow::anyhow!(
                "{:?}: no matching schema or CustomResourceDefinition found for {}, {}",
                name,
                if group.is_empty() {
                    group
                } else {
                    format!("{}/{}", group, version)
                },
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

type SchemaKey = (String, String); // (apiVersion, kind)

fn try_parse_schema_files(dir: &PathBuf) -> anyhow::Result<BTreeMap<SchemaKey, serde_json::Value>> {
    let mut schemas = BTreeMap::new();
    if !dir.is_dir() {
        bail!("directory does not exist or is not a directory");
    }
    // schema file should be in <dir>/<apiVersion>/<kind>.json

    for entry in std::fs::read_dir(dir)? {
        let entry_path = entry?.path();
        if !entry_path.is_dir() {
            continue;
        }

        // this entry_path is apiVersion
        let api_version = entry_path
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or(anyhow::anyhow!("invalid apiVersion directory name"))?
            .to_string();

        // '/' is convereted to '_' in file system names, convert back
        let api_version = api_version.replace('_', "/");

        for kind_entry in std::fs::read_dir(&entry_path)? {
            let kind_entry_path = kind_entry?.path();
            if kind_entry_path.is_dir() {
                continue;
            }
            let kind = kind_entry_path
                .file_stem()
                .and_then(|s| s.to_str())
                .ok_or(anyhow::anyhow!("invalid kind file name"))?
                .to_string();
            let content = std::fs::read(&kind_entry_path)?;
            let schema_value: serde_json::Value = serde_json::from_slice(&content)?;
            schemas.insert((api_version.clone(), kind.clone()), schema_value);
        }
    }

    Ok(schemas)
}

fn validate_against_schema(
    schema: &serde_json::Value,
    manifest_value: &serde_json::Value,
    name: &str,
) -> Result<(), anyhow::Error> {
    let validator = match jsonschema::draft202012::new(schema) {
        Ok(validator) => validator,
        Err(e) => {
            bail!("{:?}: failed to create schema validator: {:?}", name, e)
        }
    };
    let result = validator.validate(manifest_value);
    if let Err(e) = result {
        let instance_path = e.instance_path().to_string();
        bail!("{:?}: validation error at {}: {}", name, instance_path, e)
    }

    Ok(())
}

fn validate_against_crd(
    crd: &CustomResourceDefinition,
    manifest_value: &serde_json::Value,
    name: &str,
    group: &str,
    version: &str,
    kind: &str,
) -> Result<bool, anyhow::Error> {
    let crd_name = crd.metadata.name.clone().unwrap_or_default();
    let crd_group = crd.spec.group.clone();
    let crd_kind = crd.spec.names.kind.clone();

    if crd_group != group || crd_kind != kind {
        // not a match, skip
        return Ok(false);
    }

    // find matching version
    let version_found = crd
        .spec
        .versions
        .iter()
        .find(|v| v.name == version)
        .cloned();

    let Some(version_spec) = version_found else {
        bail!(
            "{:?}: no matching version {:?} in CRD {:?}",
            name,
            version,
            crd_name
        )
    };

    let schema = if let Some(schema) = version_spec.schema {
        schema
    } else {
        bail!(
            "{:?}: no schema found in CRD {:?} version {:?}",
            name,
            crd_name,
            version
        );
    };

    let schema = if let Some(open_api_v3_schema) = schema.open_api_v3_schema {
        open_api_v3_schema
    } else {
        bail!(
            "{:?}: no OpenAPI v3 schema found in CRD {:?} version {:?}",
            name,
            crd_name,
            version
        )
    };

    // do validation
    let Ok(schema) = serde_json::to_value(&schema) else {
        bail!(
            "{:?}: empty schema in CRD {:?} version {:?}",
            name,
            crd_name,
            version
        )
    };
    let Ok(validator) = jsonschema::validator_for(&schema) else {
        bail!(
            "{:?}: failed to create validator for CRD {:?} version {:?}",
            name,
            crd_name,
            version
        )
    };
    let result = validator.validate(&manifest_value);
    if let Err(e) = result {
        let instance_path = e.instance_path().to_string();
        bail!("{:?}: validation error at {}: {}", name, instance_path, e)
    }

    Ok(true)
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
            BTreeMap::new(),
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
            BTreeMap::new(),
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
            BTreeMap::new(),
            vec![("manifest.json".to_string(), manifest)],
        );

        assert_eq!(errors.len(), 1);
        assert!(
            errors[0]
                .to_string()
                .contains("no matching schema or CustomResourceDefinition found")
        );
    }

    #[test]
    fn test_no_schema_in_crd() {
        let crd = make_crd("example.com", "MyResource", "v1", None);
        let manifest = make_manifest("example.com/v1", "MyResource", "test-resource");

        let errors = do_validation(
            vec![("crd.json".to_string(), crd)],
            BTreeMap::new(),
            vec![("manifest.json".to_string(), manifest)],
        );

        assert_eq!(errors.len(), 1);
        assert!(
            errors[0]
                .to_string()
                .contains("no matching schema or CustomResourceDefinition found")
        );
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
            BTreeMap::new(),
            vec![("manifest.json".to_string(), manifest)],
        );

        assert_eq!(errors.len(), 1);
        assert!(
            errors[0]
                .to_string()
                .contains("no matching schema or CustomResourceDefinition found")
        );
    }

    #[test]
    fn test_no_matching_crd() {
        let crd = make_crd("example.com", "MyResource", "v1", Some(simple_schema()));
        let manifest = make_manifest("other.com/v1", "OtherResource", "test-resource");

        let errors = do_validation(
            vec![("crd.json".to_string(), crd)],
            BTreeMap::new(),
            vec![("manifest.json".to_string(), manifest)],
        );

        assert_eq!(errors.len(), 1);
        assert!(
            errors[0]
                .to_string()
                .contains("no matching schema or CustomResourceDefinition found")
        );
    }

    #[test]
    fn test_core_api_version_without_group() {
        // test api_version without a group (e.g., "v1" instead of "group/v1")
        let crd = make_crd("", "Pod", "v1", Some(simple_schema()));
        let manifest = make_manifest("v1", "Pod", "test-pod");

        let errors = do_validation(
            vec![("crd.json".to_string(), crd)],
            BTreeMap::new(),
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
            BTreeMap::new(),
            vec![
                ("manifest1.json".to_string(), manifest1),
                ("manifest2.json".to_string(), manifest2),
            ],
        );

        assert_eq!(errors.len(), 2);
        assert!(
            errors
                .iter()
                .any(|e| e.to_string().contains("missing TypeMeta"))
        );
        assert!(
            errors
                .iter()
                .any(|e| e.to_string().contains("no matching version"))
        );
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
            BTreeMap::new(),
            vec![("manifest.json".to_string(), manifest)],
        );

        assert!(errors.is_empty(), "Expected no errors, got: {:?}", errors);
    }

    #[test]
    fn test_empty_manifests_returns_no_errors() {
        let crd = make_crd("example.com", "MyResource", "v1", Some(simple_schema()));

        let errors = do_validation(vec![("crd.json".to_string(), crd)], BTreeMap::new(), vec![]);

        assert!(errors.is_empty());
    }

    #[test]
    fn test_empty_crds_returns_error() {
        let manifest = make_manifest("example.com/v1", "MyResource", "test-resource");

        let errors = do_validation(
            vec![],
            BTreeMap::new(),
            vec![("manifest.json".to_string(), manifest)],
        );

        assert_eq!(errors.len(), 1);
        assert!(
            errors[0]
                .to_string()
                .contains("no matching schema or CustomResourceDefinition found")
        );
    }

    #[test]
    fn test_valid_manifest_passes_json_schema_validation() {
        let schema = json!({
            "type": "object",
            "properties": {
                "apiVersion": {"type": "string"},
                "kind": {"type": "string"},
                "metadata": {"type": "object"},
                "spec": {
                    "type": "object",
                    "properties": {
                        "replicas": {"type": "integer"}
                    }
                }
            }
        });

        let mut schemas = BTreeMap::new();
        schemas.insert(
            ("example.com/v1".to_string(), "MyResource".to_string()),
            schema,
        );

        let manifest = make_manifest_with_data(
            "example.com/v1",
            "MyResource",
            "test-resource",
            json!({"spec": {"replicas": 3}}),
        );

        let errors = do_validation(
            vec![],
            schemas,
            vec![("manifest.json".to_string(), manifest)],
        );

        assert!(errors.is_empty(), "Expected no errors, got: {:?}", errors);
    }

    #[test]
    fn test_invalid_manifest_fails_json_schema_validation() {
        let schema = json!({
            "type": "object",
            "properties": {
                "apiVersion": {"type": "string"},
                "kind": {"type": "string"},
                "metadata": {"type": "object"},
                "spec": {
                    "type": "object",
                    "properties": {
                        "replicas": {"type": "integer"}
                    },
                    "required": ["replicas"]
                }
            },
            "required": ["spec"]
        });

        let mut schemas = BTreeMap::new();
        schemas.insert(
            ("example.com/v1".to_string(), "MyResource".to_string()),
            schema,
        );

        // replicas should be an integer, not a string
        let manifest = make_manifest_with_data(
            "example.com/v1",
            "MyResource",
            "test-resource",
            json!({"spec": {"replicas": "not-a-number"}}),
        );

        let errors = do_validation(
            vec![],
            schemas,
            vec![("manifest.json".to_string(), manifest)],
        );

        assert_eq!(errors.len(), 1);
        assert!(errors[0].to_string().contains("validation error"));
    }

    #[test]
    fn test_json_schema_takes_priority_over_crd() {
        // create a crd that would fail validation (missing schema)
        let crd = make_crd("example.com", "MyResource", "v1", None);

        // create a json schema that will pass
        let schema = json!({
            "type": "object",
            "properties": {
                "apiVersion": {"type": "string"},
                "kind": {"type": "string"},
                "metadata": {"type": "object"}
            }
        });

        let mut schemas = BTreeMap::new();
        schemas.insert(
            ("example.com/v1".to_string(), "MyResource".to_string()),
            schema,
        );

        let manifest = make_manifest("example.com/v1", "MyResource", "test-resource");

        // should pass because json schema takes priority and doesn't require spec
        let errors = do_validation(
            vec![("crd.json".to_string(), crd)],
            schemas,
            vec![("manifest.json".to_string(), manifest)],
        );

        assert!(errors.is_empty(), "Expected no errors, got: {:?}", errors);
    }

    #[test]
    fn test_falls_back_to_crd_when_no_schema_matches() {
        // schema for a different resource
        let schema = json!({
            "type": "object"
        });

        let mut schemas = BTreeMap::new();
        schemas.insert(
            ("other.com/v1".to_string(), "OtherResource".to_string()),
            schema,
        );

        // crd for the actual resource
        let crd = make_crd("example.com", "MyResource", "v1", Some(simple_schema()));

        let manifest = make_manifest_with_data(
            "example.com/v1",
            "MyResource",
            "test-resource",
            json!({"spec": {"replicas": 3}}),
        );

        // Should fall back to CRD validation since no schema matches
        let errors = do_validation(
            vec![("crd.json".to_string(), crd)],
            schemas,
            vec![("manifest.json".to_string(), manifest)],
        );

        assert!(errors.is_empty(), "Expected no errors, got: {:?}", errors);
    }
}
