{
  pkgs,
  config,
  ...
}:
let
  fetchSchema =
    { url, hash }:
    builtins.fetchurl {
      inherit url hash;
    };
in
{
  # TODO
}
