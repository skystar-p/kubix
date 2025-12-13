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

  userManifests =
    let
      processedManifests = lib.filter (x: x.manifest != null) (
        lib.mapAttrsToList (k: v: {
          name = k;
          manifest = applyPostProcessors v config.kubix.postProcessors;
        }) config.kubix.manifests
      );
    in
    pkgs.linkFarm "manifest-dir" (
      map (x: {
        name = "${x.name}.json";
        path = pkgs.writeText x.name (builtins.toJSON x.manifest);
      }) processedManifests
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
      userManifests
      helmManifests
    ];
  };

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

      nativeBuildInputs = [
        pkgs.yq-go
      ]
      ++ lib.optionals helmOptions.tarball [
        pkgs.kubernetes-helm
      ];

      phases = [ "installPhase" ];

      installPhase = ''
        mkdir -p $out
        tempDir=$(mktemp -d)

        chartDir="$tempDir/${helmOptions.name}"
        mkdir -p "$chartDir/templates"

        cat <<EOF > "$chartDir/Chart.yaml"
        ${chartYAML}
        EOF

        # convert JSON manifests to YAML and copy to templates
        for f in "${allManifests}"/**/*.json; do
          if [ -f "$f" ]; then
            dirName=$(dirname "$f")
            fileName=$(basename "$dirName" ".json")
            mkdir -p "$chartDir/templates/$dirName"
            yq -P '.' "$f" > "$chartDir/templates/$dirName/$fileName.yaml"
          fi
        done
        ${
          if helmOptions.tarball then
            ''
              # dereference all symlinks
              tempPackageDir="$tempDir/tempChartDir"
              cp -rL "$chartDir" "$tempPackageDir"
              chmod -R u+w "$tempPackageDir"
              helm package "$tempPackageDir" --destination "$out"
            ''
          else
            ''
              # if not packaging as tarball, copy the chart directly to output
              cp -r "$chartDir" "$out/"
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
