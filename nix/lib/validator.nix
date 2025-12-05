{
  pkgs,
  config,
  ...
}:
let
  fetchSchema =
    { url, hash }:
    pkgs.fetchurl {
      inherit url hash;
    };
in
{
}
