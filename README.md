# kubix

A Kubernetes manifest generator, powered by Nix.

## Why?

Managing Kubernetes manifests is... painful. Hand-written YAML is error-prone, and you won't know your manifests are broken until you `kubectl apply` them to a cluster. Helm helps with templating but it's just text substitution—there's no guarantee the rendered output is valid (it can even generate invalid YAML!).

Kubix solves this by:

- **Catching errors at build time**: All manifests are validated against JSON Schema before they're even written. Typos, missing required fields, and type mismatches fail the manifest generation, not the deployment.
- **Using Nix for configuration**: Write manifests in a real programming language with proper types, functions, and abstractions. No more YAML indentation disasters and `nindent` workaround.
- **Validating Helm outputs**: Render Helm charts and validate the result. Finally know if your `values.yaml` produces valid Kubernetes resources.
- **Supporting CRDs**: Automatically extract schemas from `CustomResourceDefinition`s. Your cert-manager `Certificate`s and Istio `VirtualService`s get validated too.
- **Post-Processing your final result**: You have full control over your manifests, powered by Nix function. No more custom forked Helm charts for your real needs.
- **Building Helm chart with validations**: You can even make basic Helm chart with custom values, and the chart rendered with provided default values are also validated.

If you're tired of debugging YAML in production, give Kubix a try. It makes writing manifest a more pleasant experience.


- [Basic Usage](#basic-usage)
- [Validating your manifests](#validating-your-manifests)
- [Use your custom JSON Schema](#use-your-custom-json-schema)
- [Use CustomResourceDefinition instead](#use-customresourcedefinition-instead)
- [Using Helm chart](#using-helm-chart)
  - [Using Helm chart containing CustomResourceDefinition resources](#using-helm-chart-containing-customresourcedefinition-resources)
- [Use Post-processors to tailor your output](#use-post-processors-to-tailor-your-output)
- [Build output as Helm chart](#build-output-as-helm-chart)
  - [Add Helm template variables](#add-helm-template-variables)
  - [Create JSON schema for `values.yaml`](#create-json-schema-for-valuesyaml)

## Basic Usage

Write your Kubernetes manifest with your familiar Nix language, like this.

```nix
# manifest.nix
{
  example-configmap = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "example-configmap";
      namespace = "default";
    };
    data = {
      "cool-data" = "foo";
      "awesome-data" = "bar";
    };
  };
}
```

and use it in your flake.
```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    kubix.url = "github:skystar-p/kubix";
  };

  outputs =
    { flake-utils, kubix, ... }:
    flake-utils.lib.eachDefaultSystem (system: {
      # use `kubix.lib.buildManifests` to validate the manifest and produce output!
      packages.default = kubix.lib.buildManifests system {
        manifests = import ./manifest.nix;
      };
    });
}
```

...and build.

```bash
nix build
# during build process, all manifests are strictly checked with JSON schema.

ls -al ./result
# lrwxrwxrwx - root  1 Jan  1970 example-configmap.json -> /nix/store/wcz3zsj4r22hsk7ip32w9d89aa38lahc-example-configmap

# you can safely apply the output.
cd ./result
kubectl apply -f .
```

## Validating your manifests

All of your given manifests are strictly validated with JSON Schema. See this example.

```nix
# manifest.nix
{
  example-configmap = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "example-configmap";
      namespace = "default";
    };
    data = {
      "cool-data" = "foo";
      "wrong-data" = 12345; # This value should be a string, but it is a number!
    };
  };
}
```

What will happen when you build this?

```bash
nix build

# error: Cannot build '/nix/store/2djixn2avimz4g802mih2s628xkyymn0-validator.drv'.
#        Reason: builder failed with exit code 1.
#        Output paths:
#          /nix/store/140xlyahm4cr3m0bb0aid1wiznqh27cn-validator
#        Last 2 log lines:
#        > Error: "example-configmap.json": validation error at /data/wrong-data: 12345 is not of types "null", "string"
#        > Error: validation failed with 1 errors
#        For full logs, run:
#          nix log /nix/store/2djixn2avimz4g802mih2s628xkyymn0-validator.drv
```

Kubix kindly alerts you, what fields are missing or wrong, and why.

## Use your custom JSON Schema

Predefined schemas in this repository may be not enough for your manifest use cases. In this case, you can add additional schema definition option. Just provide the schema to the Kubix module.

```nix
# manifest.nix
{
  example-certificate = {
    apiVersion = "cert-manager.io/v1";
    kind = "Certificate";
    metadata = {
      name = "example-com-tls";
      namespace = "default";
    };
    spec = {
      secretName = "example-com-tls";
      dnsNames = [ "example.com" ];
      issuerRef = {
        name = "letsencrypt-prod";
        kind = "ClusterIssuer";
      };
    };
  };
}
```

```nix
# schema.nix
[
  {
    apiVersion = "cert-manager.io/v1";
    kind = "Certificate";
    url = "https://raw.githubusercontent.com/datreeio/CRDs-catalog/6f4f838cdf656cef2fbc1792361f28af2740f705/cert-manager.io/certificate_v1.json";
    hash = "sha256-P7hXYDA7zqstFpIjcMW1E1AyINiWVnbz4qE44MIY8Ac=";
  }
]
```

```nix
# flake.nix
{
  # ...

  packages.default = kubix.lib.buildManifests system {
    # provide your own schema!
    schemas = import ./schema.nix;
    manifests = import ./manifest.nix;
  };
}
```

No more worry about errors in your manifest. For example, if you've forgot to specify `secretName` on your `Certificate`:

```nix
# manifest.nix
{
  example-certificate = {
    apiVersion = "cert-manager.io/v1";
    kind = "Certificate";
    metadata = {
      name = "example-com-tls";
      namespace = "default";
    };
    spec = {
      # Oops!
      # secretName = "example-com-tls";
      dnsNames = [ "example.com" ];
      issuerRef = {
        name = "letsencrypt-prod";
        kind = "ClusterIssuer";
      };
    };
  };
}
```

```bash
nix build

# error: Cannot build '/nix/store/jpybm5d6frmgkssr75awd1cw020256r0-validator.drv'.
#        Reason: builder failed with exit code 1.
#        Output paths:
#          /nix/store/bms2819yzal7zjc4xj9h8ixz9zjyqr6s-validator
#        Last 2 log lines:
#        > Error: "example-certificate.json": validation error at /spec: "secretName" is a required property
#        > Error: validation failed with 1 errors
#        For full logs, run:
#          nix log /nix/store/jpybm5d6frmgkssr75awd1cw020256r0-validator.drv
```

Validating and building manifests is simple as that.

## Use CustomResourceDefinition instead

Worried about not having a JSON schema files? No sweat. Kubix can understand `CustomResourceDefinition` YAMLs as well. Just throw your CRD files into Kubix module.

```nix
# crd.nix
[
  {
    url = "https://raw.githubusercontent.com/cert-manager/cert-manager/02d1e1985e5c94059c5a2c3653b3d98c27a9c8f9/deploy/crds/cert-manager.io_certificates.yaml";
    hash = "sha256-c73XIW4DLjSCF5aKb02E6FqOdwkGEklWgGFpHXljHxA=";
  }
]
```

```nix
# flake.nix
{
  # ...

  packages.default = kubix.lib.buildManifests system {
    # provide CustomResourceDefinition yamls!
    crds = import ./crd.nix;
    manifests = import ./manifest.nix;
  };
}
```

It is simple as that.

## Using Helm chart

Many people use Helm to render manifests for deployments. Unfortunately, Helm is just a dumb text templating tool, so there is no guarantee that the rendered manifest will work when applied to your cluster.

Here's the thing. Kubix can include arbitrary Helm charts in your manifest and verify whether the rendered result is templated incorrectly.

```nix
# charts.nix
{
  cert-manager = {
    repo = "https://charts.jetstack.io";
    chartName = "cert-manager";
    chartVersion = "v1.19.1";
    hash = "sha256-fs14wuKK+blC0l+pRfa//oBV2X+Dr3nNX+Z94nrQVrA=";

    namespace = "cert-manager";
    values = {
      # provide your values.yaml in Nix!
    };
}
```

```nix
# flake.nix
{
  # ...

  packages.default = kubix.lib.buildManifests system {
    helmCharts = import ./charts.nix;
  };
}
```

### Using Helm chart containing CustomResourceDefinition resources

If a Helm chart contains `CustomResourceDefinition`, Kubix will automatically import them and verify your given custom resource manifests!

```nix
# charts.nix
{
  cert-manager = {
    repo = "https://charts.jetstack.io";
    chartName = "cert-manager";
    chartVersion = "v1.19.1";
    hash = "sha256-fs14wuKK+blC0l+pRfa//oBV2X+Dr3nNX+Z94nrQVrA=";

    namespace = "cert-manager";
    values = {
      # include CRDs!
      crds.enabled = true;
    };
}
```

```nix
# manifest.nix
{
  # even if you don't provide the CRD, Kubix will automatically import the CRDs
  # from the Helm chart rendered result!
  example-certificate = {
    apiVersion = "cert-manager.io/v1";
    kind = "Certificate";
    metadata = {
      name = "example-com-tls";
      namespace = "default";
    };
    spec = {
      secretName = "example-com-tls";
      dnsNames = [ "example.com" ];
      issuerRef = {
        name = "letsencrypt-prod";
        kind = "ClusterIssuer";
      };
    };
  };
}
```

```nix
# flake.nix
{
  # ...

  packages.default = kubix.lib.buildManifests system {
    # No need to provide CRD options.
    helmCharts = import ./charts.nix;
    manifests = import ./manifest.nix;
  };
}
```

## Use Post-processors to tailor your output

You can use `postProcessors` option to mutate your final output to tailor for your need. This kind of "bulk-processor" is useful in some cases, for example:

* You want to "enforce" labels or annotations to your resources to track your cloud cost.
* You want to remove the whole manifest if some conditions are met.
* You want to customize your helm chart's output further, but there is no `values` knobs to control that.

All manifests are validated after the post-processors are applied, so you don't have to worry about your mistake in post-processor functions. Nice!

Use it like this:

```nix
# manifest.nix
{
  example-configmap = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "example-configmap";
      namespace = "default";
    };
    data = {
      "cool-data" = "foo";
      "awesome-data" = "bar";
      "boring-data" = "baz";
    };
  };
}
```

```nix
# postProcessors.nix
{ lib, ... }:
[
  {
    name = "add exciting data";
    predicate = manifest: manifest.kind == "ConfigMap" && manifest.metadata.name == "example-configmap";
    mutate =
      manifest:
      let
        mutated = lib.recursiveUpdate manifest {
          data = {
            "exciting-data" = "qux";
          };
        };
      in
      mutated;
  }
]
```

```nix
# flake.nix
{
  # ...

  packages.default = kubix.lib.buildManifests system {
    manifests = import ./manifest.nix;
    postProcessors = import ./postProcessors.nix { inherit lib };
  };
}
```

Then the result looks like:
```json
{
  "apiVersion": "v1",
  "kind": "ConfigMap",
  "metadata": {
    "name": "example-configmap",
    "namespace": "default"
  },
  "data": {
    "cool-data": "foo",
    "awesome-data": "bar",
    "boring-data": "baz",
    "exciting-data": "qux" # <-- this is added by post-processor!
  }
}
```

You can also do your own validation on your manifests. Just `throw` the error in `mutate` function. If you do like this:

```nix
# postProcessors.nix
{ lib, ... }:
[
  {
    name = "no boring data";
    predicate = manifest: manifest.kind == "ConfigMap" && manifest.metadata.name == "example-configmap";
    mutate =
      manifest:
      if builtins.hasAttr "boring-data" manifest.data then
        throw "No boring data allowed in my manifests!"
      else
        manifest;
  }
]
```

Then the build will fail like this message:
```
error: kubix: post-processor mutation failed for: "no boring data"

manifest information:
  apiVersion: "v1"
  kind: "ConfigMap"
  name: "example-configmap"
  namespace: "default"
```

## Build output as Helm chart

You can make your final output into Helm chart. This can be useful if you need Helm chart in your CI/CD pipeline.

```nix
# flake.nix
{
  # ...

  packages.default = kubix.lib.buildManifests system {
    manifests = import ./manifest.nix;

    outputType = {
      type = "helm";

      helmOptions = {
        name = "test-helm";
        tarball = true; # default is false
        createValuesSchema = true; # default is true
      };
    };
  };
}
```

Then you can call `helm template` command to output.

```sh
nix build

helm template "my-helm-chart" ./result
```

### Add Helm template variables

Kubix provides special type named `kubix.lib.helmValue`, which can be rendered later as Helm template string. You can build basic Helm charts which accepts custom `values.yaml`. To compose strings that combine multiple Helm values or literals, wrap the pieces in `kubix.lib.helmTemplate [ ... ]`.

```nix
# manifest.nix
{
  example-configmap = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "example-configmap";
      namespace = "default";
    };
    data = {
      # use `kubix.lib.helmValue` to construct helm template string.
      "cool-data" = kubix.lib.helmValue [ "configMap" "coolDataValue" ] "defaultValue";
      # use `kubix.lib.helmTemplate` to combine multiple Helm values/literals into one string.
      "cool-name" = kubix.lib.helmTemplate [
        (kubix.lib.helmValue [ "configMap" "namePrefix" ] "coolNamePrefix")
        "-"
        (kubix.lib.helmValue [ "configMap" "nameSuffix" ] "coolNameSuffix")
      ];
    };
  };
}
```

Then if you set output type as `helm`, that `kubix.lib.helmValue` types are rendered as Helm template strings.

```sh
nix build

# you can call `helm template` to build output
helm template example-chart result
```

Templated result is:
```json
{
  "apiVersion": "v1",
  "data": {
    "cool-data": "defaultValue", # <-- default value is provided
    "cool-name": "coolNamePrefix-coolNameSuffix" # <-- template strings can be composed
  },
  "kind": "ConfigMap",
  "metadata": {
    "name": "example-configmap",
    "namespace": "default"
  }
}
```

If you pass `--set` arguments to set value parameters:
```sh
helm template example-chart result --set configMap.coolDataValue='This is custom value!'
```

```json
{
  "apiVersion": "v1",
  "data": {
    "cool-data": "This is custom value!", # <-- can be customized!
    "cool-name": "coolNamePrefix-coolNameSuffix"
  },
  "kind": "ConfigMap",
  "metadata": {
    "name": "example-configmap",
    "namespace": "default"
  }
}
```

If you did not specified ouptut type as `helm`, default values provided are used to render manifests.
Also, all validation processes are done with default values, so you don't have to worry about your mistake when using `kubix.lib.helmValue`.

### Create JSON schema for `values.yaml`

If you specify `createValuesSchema` option to `true` (which is the default), Kubix creates `values.schema.json` file in your chart, so that you can get validated your `values.yaml` file when you render your chart. This validation is done by Helm, so your custom `values.yaml` is safe from mistake.

For example, if you provide this invalid `values.yaml` file,
```yaml
# values.yaml

configMap:
  coolDataValue: 100 # this is invalid!
  
  namePrefix: "coolNamePrefix"
  nameSuffix: "coolNameSuffix"
```

Then `helm template` command will fail with validation error:
```sh
❯ helm template example-chart result -f values.yaml

Error: values don't meet the specifications of the schema(s) in the following chart(s):
example-chart:
- at '/configMap/coolDataValue': got number, want string
```
