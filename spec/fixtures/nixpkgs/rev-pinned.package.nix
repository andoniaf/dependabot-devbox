{
  lib,
  fetchFromGitHub,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "rev-pinned";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "example-org";
    repo = "example-repo";
    rev = "9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0";
    hash = "sha256-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK=";
  };
}
