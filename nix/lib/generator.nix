{
  pkgs,
  lib,
  config,
  ...
}:
let
  fetch = { url, hash, ... }: pkgs.fetchurl { inherit url hash; };

  applyPostProcessors =
    manifest: postProcessors:
    lib.foldl' (
      acc: processor:
      if acc == null then
        null
      else if (processor.predicate manifest) == true then
        let
          result = builtins.tryEval (processor.mutate acc);
        in
        if result.success then
          result.value
        else
          let
            processorName = if processor.name != null then processor.name else "<unnamed>";
          in
          throw ''
            kubix: post-processor mutation failed for: "${processorName}"

            manifest information:
              apiVersion: "${manifest.apiVersion}"
              kind: "${manifest.kind}"
              name: "${manifest.metadata.name or "<null>"}"
              namespace: "${manifest.metadata.namespace or "<null>"}"
          ''
      else
        manifest
    ) manifest postProcessors;

  renderHelmTemplate =
    parts: renderHelmValue:
    lib.concatStrings (
      map (
        part:
        if builtins.isString part then
          part
        else if builtins.isBool part || builtins.isInt part || builtins.isFloat part then
          builtins.toString part
        else if builtins.isAttrs part && part ? __kubixHelmValue then
          renderHelmValue part.__kubixHelmValue
        else if builtins.isAttrs part && part ? __kubixHelmTemplate then
          renderHelmTemplate part.__kubixHelmTemplate.parts renderHelmValue
        else
          throw "kubix: unsupported value found in helm template parts"
      ) parts
    );

  replaceKubixHelmValuesWithDefault =
    let
      replace =
        v:
        if builtins.isAttrs v && v ? __kubixHelmValue then
          v.__kubixHelmValue.default
        else if builtins.isAttrs v && v ? __kubixHelmTemplate then
          renderHelmTemplate v.__kubixHelmTemplate.parts (helmValue: builtins.toString helmValue.default)
        else if builtins.isList v then
          map replace v
        else if builtins.isAttrs v then
          builtins.mapAttrs (_: val: replace val) v
        else
          v;
    in
    replace;

  replaceKubixHelmValuesWithPlaceholder =
    let
      mkPlaceholder =
        type: expr:
        let
          placeholder = if type == "string" then "KUBIX_HELM_RAW_STRING" else "KUBIX_HELM_RAW";
        in
        "$$${placeholder}$$(" + expr + ")$$END_${placeholder}$$";
      replace =
        v:
        if builtins.isAttrs v && v ? __kubixHelmValue then
          mkPlaceholder (builtins.typeOf v.__kubixHelmValue.default) (
            "{{ .Values." + (lib.concatStringsSep "." v.__kubixHelmValue.path) + " }}"
          )
        else if builtins.isAttrs v && v ? __kubixHelmTemplate then
          renderHelmTemplate v.__kubixHelmTemplate.parts (
            helmValue:
            mkPlaceholder "string" ("{{ .Values." + (lib.concatStringsSep "." helmValue.path) + " }}")
          )
        else if builtins.isList v then
          map replace v
        else if builtins.isAttrs v then
          builtins.mapAttrs (_: val: replace val) v
        else
          v;
    in
    replace;

  userManifests =
    helmValueProcessor:
    let
      processedManifests = lib.filterAttrs (_: v: v != null) (
        builtins.mapAttrs (_: v: applyPostProcessors v config.kubix.postProcessors) config.kubix.manifests
      );
      helmValueReplacedManifests = builtins.mapAttrs (_: v: helmValueProcessor v) processedManifests;
    in
    helmValueReplacedManifests;

  userManifestFiles =
    helmValueProcessor:
    pkgs.linkFarm "manifest-dir" (
      lib.mapAttrsToList (
        k: v:
        let
          name = "${k}.json";
        in
        {
          inherit name;
          path = pkgs.writeText name (builtins.toJSON v);
        }
      ) (userManifests helmValueProcessor)
    );

  predefinedSchemas =
    if builtins.pathExists ../lib/schemas/${config.kubix.kubernetesVersion}.nix then
      import ../lib/schemas/${config.kubix.kubernetesVersion}.nix
    else
      builtins.trace (
        "warning: no predefined schemas found for Kubernetes version ${config.kubix.kubernetesVersion}. please make sure to define all required schemas in config.kubix.schemas."
      ) [ ];

  userManifestTypes = lib.unique (
    lib.mapAttrsToList (_: manifest: { inherit (manifest) apiVersion kind; }) config.kubix.manifests
  );

  helmManifestTypes = lib.concatLists (
    lib.map (
      helmResult:
      let
        schemaTypes = builtins.fromJSON (builtins.readFile helmResult.schemaTypesPath);
      in
      lib.map (schemaType: { inherit (schemaType) apiVersion kind; }) schemaTypes
    ) helmTemplateResults
  );

  allManifestTypes = lib.unique (userManifestTypes ++ helmManifestTypes);

  userSchemaTypes = lib.map (schema: {
    apiVersion = schema.apiVersion;
    kind = schema.kind;
  }) config.kubix.schemas;

  filteredPredefinedSchemas = lib.filter (
    schema:
    (
      # filter schemas that are actually used in manifests
      builtins.any (
        manifestType: schema.apiVersion == manifestType.apiVersion && schema.kind == manifestType.kind
      ) allManifestTypes
      # and not overridden by user-defined schemas
      && !builtins.any (
        schemaType: schema.apiVersion == schemaType.apiVersion && schema.kind == schemaType.kind
      ) userSchemaTypes
    )
  ) predefinedSchemas;

  allSchemas = lib.concatLists [
    config.kubix.schemas
    (lib.map (schema: {
      inherit (schema)
        apiVersion
        kind
        url
        hash
        ;
      path = schema.path or null;
    }) filteredPredefinedSchemas)
  ];

  schemaDir = pkgs.runCommand "schema-dir" { } (
    lib.concatStringsSep "\n" (
      [ "mkdir -p $out" ]
      ++ lib.map (
        schema:
        let
          schemaPath = if schema.path != null then schema.path else fetch schema;
          normalizedApiVersion = lib.replaceStrings [ "/" ] [ "_" ] schema.apiVersion;
        in
        ''
          mkdir -p "$out/${normalizedApiVersion}"
          cp "${schemaPath}" "$out/${normalizedApiVersion}/${schema.kind}.json"
        ''
      ) allSchemas
    )
  );

  crdDir = pkgs.runCommand "crd-dir" { nativeBuildInputs = [ pkgs.yq-go ]; } (
    lib.concatStringsSep "\n" (
      [ "mkdir -p $out" ]
      ++ lib.imap0 (i: v: ''
        yq -o=json '.' "${fetch v}" > "$out/crd-${toString i}.json"
      '') config.kubix.crds
      ++ lib.map (result: ''
        cp "${result.crdsPath}" "$out"/helm-crd-${result.name}
      '') helmTemplateResults
    )
  );

  pullHelmChart =
    {
      repo,
      chartName,
      chartVersion,
      hash,
      extraArgs ? [ ],
    }:
    let
      repoArg =
        if (pkgs.lib.hasPrefix "oci://" repo) then
          "${repo}/${chartName}"
        else
          ''--repo "${repo}" "${chartName}"'';
    in
    pkgs.stdenv.mkDerivation {
      name = "pull-helm-chart-${chartName}-${chartVersion}";

      nativeBuildInputs = with pkgs; [
        kubernetes-helm
        cacert
      ];

      phases = [ "installPhase" ];

      installPhase = ''
        tempDir=$(mktemp -d)
        mkdir -p "$tempDir/cache"
        export HELM_CACHE_HOME="$tempDir/cache"

        helm pull \
          ${repoArg} \
          --destination "$tempDir" \
          --untar \
          --version "${chartVersion}" \
          ${lib.concatStringsSep " " extraArgs}

        mv "$tempDir/${chartName}" "$out"
      '';

      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = hash;
    };

  templateHelmCharts =
    {
      name,
      chart,
      namespace,
      values,
      includeCRDs ? true,
      kubeVersion ? null,
      apiVersions ? [ ],
      extraArgs ? [ ],
    }:
    let
      outputName = "helm-${namespace}-${name}";
    in
    pkgs.stdenv.mkDerivation {
      name = outputName;

      nativeBuildInputs = with pkgs; [
        kubernetes-helm
        yq-go
        jq
      ];

      valueJSON = builtins.toJSON values;
      passAsFile = [ "valueJSON" ];

      phases = [ "installPhase" ];

      installPhase = ''
        tempDir=$(mktemp -d)
        mkdir -p "$tempDir/cache"
        export HELM_CACHE_HOME="$tempDir/cache"

        helm template \
          "${name}" \
          "${chart}" \
          ${if namespace != "" then ''--namespace "${namespace}"'' else ""} \
          ${if includeCRDs then "--include-crds" else ""} \
          ${if kubeVersion != null then ''--kube-version "${kubeVersion}"'' else ""} \
          --values "$valueJSONPath" \
          ${builtins.concatStringsSep " " (lib.map (v: ''--api-versions "${v}"'') apiVersions)} \
          ${lib.concatStringsSep " " extraArgs} \
          >> "$tempDir/output.yaml"

        mkdir -p $out
        mkdir -p $out/${outputName}
        yq -o=json '.' "$tempDir/output.yaml" | jq -s '.' >> "$tempDir/all-manifests.json"
        # convert templated yaml to jsons
        yq -o=json '.' "$tempDir/output.yaml" | jq -s '.' | jq -c '.[]' | while read -r manifest; do
          apiVersion=$(jq -e -r '.apiVersion | gsub("/"; "_")' <<< "$manifest")
          kind=$(jq -e -r '.kind' <<< "$manifest")
          name=$(jq -e -r '.metadata.name' <<< "$manifest")

          echo "$manifest" | jq > "$out/${outputName}/$apiVersion-$kind-$name.json"
        done

        # list all schema types
        jq '[.[] | {apiVersion, kind}] | unique' "$tempDir/all-manifests.json" > $out/schemas-types.json
        # list all crds if any
        yq -o=json '. | select(.kind == "CustomResourceDefinition" and .apiVersion == "apiextensions.k8s.io/v1")' "$tempDir/output.yaml" | jq -s '.' >> $out/crds.json
      '';
    };

  helmTemplateResults = lib.mapAttrsToList (
    name: helmOption:
    let
      chart =
        if helmOption.localChartPath != null then
          pkgs.pathToDir helmOption.localChartPath
        else
          pullHelmChart {
            inherit (helmOption)
              repo
              chartName
              chartVersion
              hash
              ;
            extraArgs = helmOption.pullExtraArgs;
          };
      manifest = templateHelmCharts {
        inherit name chart;
        inherit (helmOption)
          namespace
          values
          includeCRDs
          kubeVersion
          apiVersions
          extraArgs
          ;
      };
      manifestDirName = "helm-${helmOption.namespace}-${name}";
    in
    {
      name = "helm-${name}";
      path = "${manifest}/${manifestDirName}";
      schemaTypesPath = "${manifest}/schemas-types.json";
      crdsPath = "${manifest}/crds.json";
    }
  ) config.kubix.helmCharts;

  helmManifests =
    let
      processedManifests = lib.concatMap (
        result:
        let
          manifestDir = result.path;
          manifestFiles = builtins.attrNames (builtins.readDir manifestDir);
          jsonFiles = lib.filter (f: lib.hasSuffix ".json" f) manifestFiles;
        in
        lib.filter (x: x.manifest != null) (
          map (file: {
            name = "${result.name}/${file}";
            manifest = applyPostProcessors (builtins.fromJSON (builtins.readFile "${manifestDir}/${file}")) config.kubix.postProcessors;
          }) jsonFiles
        )
      ) helmTemplateResults;
    in
    pkgs.linkFarm "helm-manifests" (
      map (x: {
        name = x.name;
        path = pkgs.writeText (builtins.baseNameOf x.name) (builtins.toJSON x.manifest);
      }) processedManifests
    );

  allManifests = pkgs.symlinkJoin {
    name = "all-manifests";
    paths = [
      (userManifestFiles replaceKubixHelmValuesWithDefault)
      helmManifests
    ];
  };

  allManifestsWithHelmPlaceholders = pkgs.symlinkJoin {
    name = "all-manifests-with-helm-placeholders";
    paths = [
      (userManifestFiles replaceKubixHelmValuesWithPlaceholder)
      helmManifests
    ];
  };

  collectedHelmValues =
    let
      updatePath =
        path: v: acc:
        lib.recursiveUpdate acc (lib.attrsets.setAttrByPath path v);
      update =
        acc: v:
        if builtins.isAttrs v && v ? __kubixHelmValue then
          updatePath v.__kubixHelmValue.path v.__kubixHelmValue.default acc
        else if builtins.isAttrs v && v ? __kubixHelmTemplate then
          lib.foldl' update acc v.__kubixHelmTemplate.parts
        else if builtins.isList v then
          lib.foldl' update acc v
        else if builtins.isAttrs v then
          lib.foldl' update acc (builtins.attrValues v)
        else
          acc;
      valuesAttr = lib.foldl' update { } (lib.mapAttrsToList (_: v: v) (userManifests (x: x)));
    in
    valuesAttr;

  helmValuesSchema =
    let
      mkSchema =
        v:
        let
          t = builtins.typeOf v;
          mkArraySchema = items: {
            type = "array";
            items = if items == [ ] then { } else mkSchema (builtins.head items);
            default = items;
          };
        in
        if t == "set" then
          {
            type = "object";
            properties = builtins.mapAttrs (_: mkSchema) v;
            additionalProperties = true;
            default = v;
          }
        else if t == "list" then
          mkArraySchema v
        else if t == "bool" then
          {
            type = "boolean";
            default = v;
          }
        else if t == "int" then
          {
            type = "integer";
            default = v;
          }
        else if t == "float" then
          {
            type = "number";
            default = v;
          }
        else if t == "string" then
          {
            type = "string";
            default = v;
          }
        else if t == "path" then
          {
            type = "string";
            default = builtins.toString v;
          }
        else
          { };
    in
    {
      "$schema" = "https://json-schema.org/draft-07/schema";
    }
    // mkSchema collectedHelmValues;

  helmOutput =
    let
      helmOptions = config.kubix.outputType.helmOptions;
      chartYAML = ''
        apiVersion: "${helmOptions.apiVersion}"
        name: "${helmOptions.name}"
        version: "${helmOptions.version}"
        appVersion: "${helmOptions.appVersion}"
      '';
    in
    pkgs.stdenv.mkDerivation {
      name = "helm-output-${helmOptions.name}-${helmOptions.version}";

      nativeBuildInputs =
        with pkgs;
        [
          yq-go
          perl
        ]
        ++ lib.optionals helmOptions.tarball [
          pkgs.kubernetes-helm
        ];

      phases = [ "installPhase" ];

      installPhase = ''
        tempDir=$(mktemp -d)

        chartDir="$tempDir/${helmOptions.name}"
        mkdir -p "$chartDir/templates"

        cat <<EOF > "$chartDir/Chart.yaml"
        ${chartYAML}
        EOF

        # convert JSON manifests to YAML and copy to templates
        find "${allManifestsWithHelmPlaceholders}/" -name "*.json" | while read -r f; do
          relFileName="''${f##${allManifestsWithHelmPlaceholders}/}"
          relDirName="$(dirname "$relFileName")"
          mkdir -p "$chartDir/templates/$relDirName"
          # yq -P '.' "$f" > "$chartDir/templates/$relFileName.yaml"
          yq -P '.' "$f" > "$tempDir/beforeSed.yaml"
          # replace placeholders with raw helm template syntax
          cat "$tempDir/beforeSed.yaml" | \
            perl -pe 's/"\$\$KUBIX_HELM_RAW\$\$\((.*?)\)\$\$END_KUBIX_HELM_RAW\$\$"/\1/g' | \
            perl -pe 's/\$\$KUBIX_HELM_RAW_STRING\$\$\((.*?)\)\$\$END_KUBIX_HELM_RAW_STRING\$\$/\1/g' \
            > "$chartDir/templates/$relFileName.yaml"
        done
        # write values.yaml
        yq -P '.' > "$chartDir/values.yaml" <<EOF
          ${builtins.toJSON collectedHelmValues}
        EOF
        # write values.schema.json
        cat > "$chartDir/values.schema.json" <<EOF
        ${builtins.toJSON helmValuesSchema}
        EOF
        ${
          if helmOptions.tarball then
            ''
              # dereference all symlinks
              tempPackageDir="$tempDir/tempChartDir"
              mkdir -p "$tempPackageDir"
              cp -rL "$chartDir/." "$tempPackageDir"
              chmod -R u+w "$tempPackageDir"
              helm package "$tempPackageDir" --destination "$tempDir"
              mv "$tempDir/${helmOptions.name}-${helmOptions.version}.tgz" "$out"
            ''
          else
            ''
              mkdir -p $out
              # if not packaging as tarball, copy the chart directly to output
              cp -r "$chartDir/." "$out/"
            ''
        }
        rm -rf "$tempDir"
      '';
    };
in
{
  inherit
    schemaDir
    crdDir
    allManifests
    helmOutput
    ;
}
