{
  lib,
  fetchFromGitHub,
  buildGoModule,
}:

buildGoModule (finalAttrs: {
  pname = "temporal-cli";
  version = "1.8.2";

  src = fetchFromGitHub {
    owner = "temporalio";
    repo = "cli";
    tag = "v${finalAttrs.version}";
    hash = "sha256-OBdWQLPFvXAsbjNv/Tq+75IUl31XVtpgJVCQdHQqdBw=";
  };

  vendorHash = "sha256-9lO9uhy1n85QYyoh27cKhdlcuL4GT98aCNWwe8tOwoQ=";

  meta = {
    description = "Temporal CLI";
    homepage = "https://docs.temporal.io/cli";
    license = lib.licenses.mit;
  };
})
