{
  lib,
  fetchFromGitHub,
  buildGoModule,
}:

let
  llamaCppSrc = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    tag = "b6000";
    hash = "sha256-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK=";
  };
in
buildGoModule (finalAttrs: {
  pname = "ollama";
  version = "0.12.0";

  src = fetchFromGitHub {
    owner = "ollama";
    repo = "ollama";
    tag = "v${finalAttrs.version}";
    hash = "sha256-LLLLMMMMNNNNOOOOPPPPQQQQRRRRSSSSTTTTUUUUVVV=";
  };

  vendorHash = "sha256-WWWWXXXXYYYYZZZZ0000111122223333444455556666=";

  meta = {
    description = "Get up and running with large language models locally";
    homepage = "https://ollama.com";
    license = lib.licenses.mit;
  };
})
